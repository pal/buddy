import AVFoundation
import CryptoKit
import Foundation
import BuddyCore

/// Plays Buddy's sentences in order. Renders the next sentence while the current one plays,
/// caches rendered audio on disk, and reports a mouth-opening level for lip sync.
@MainActor
final class SpeechPlayer: NSObject, VoiceOutput, AVAudioPlayerDelegate {
    var onSubtitle: ((String?) -> Void)?
    var onMouth: ((Float) -> Void)?
    var onLog: ((String) -> Void)?

    let system: SystemVoice
    private(set) var config = VoiceConfig()

    private enum Audio {
        case file(URL)
        case live
    }

    private struct Item {
        let id: Int
        let text: String
        var audio: Audio?
        var failed = false
    }

    /// The first item is the one playing (or about to play).
    private var items: [Item] = []
    private var counter = 0
    private var rendering = false
    private var generation = 0
    private var player: AVAudioPlayer?
    private var playingLive = false
    private var meterTask: Task<Void, Never>?
    private var mouth: Float = 0
    private var lastWordAt: TimeInterval = 0
    private let cacheFolder: URL
    private var stats = MouthStats()

    /// How the mouth moved during one sentence (recorded for the end-to-end tests).
    private struct MouthStats {
        var samples = 0
        var sum: Float = 0
        var max: Float = 0
        var open = 0

        mutating func add(_ level: Float) {
            samples += 1
            sum += level
            max = Swift.max(max, level)
            if level > 0.15 { open += 1 }
        }

        var fields: [String: Any] {
            [
                "samples": samples,
                "maxMouth": Double(max),
                "meanMouth": samples == 0 ? 0 : Double(sum / Float(samples)),
                "openFraction": samples == 0 ? 0 : Double(open) / Double(samples),
            ]
        }
    }

    var isBusy: Bool { !items.isEmpty }

    override init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        if let data = LaunchOptions.current.dataDirectory {
            cacheFolder = data.appendingPathComponent("Caches/tts", isDirectory: true)
        } else {
            cacheFolder = caches.appendingPathComponent("io.github.pal.buddy/tts", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
        system = SystemVoice()
        super.init()
        system.onWord = { [weak self] in
            self?.lastWordAt = Date().timeIntervalSinceReferenceDate
        }
    }

    func configure(_ newConfig: VoiceConfig) {
        config = newConfig
    }

    // MARK: VoiceOutput

    func enqueue(_ sentence: String) {
        let text = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        counter += 1
        items.append(Item(id: counter, text: text))
        pump()
    }

    func stopSpeaking() {
        if !items.isEmpty {
            EventLog.shared.record("speechStopped", ["queued": items.count])
        }
        generation += 1
        items.removeAll()
        rendering = false
        system.cancelRendering()
        player?.stop()
        player = nil
        if playingLive {
            playingLive = false
            system.stopLive()
        }
        stopMeter()
        onSubtitle?(nil)
    }

    // MARK: Queue

    private func pump() {
        if player == nil, !playingLive, let head = items.first {
            if head.failed {
                items.removeFirst()
                pump()
                return
            }
            if let audio = head.audio {
                startPlayback(head, audio)
            }
        }
        if !rendering, let next = items.first(where: { $0.audio == nil && !$0.failed }) {
            render(next)
        }
    }

    private func render(_ item: Item) {
        rendering = true
        let gen = generation
        let config = self.config
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.produceAudio(item.text, config: config)
            guard gen == self.generation else { return }
            self.rendering = false
            if let index = self.items.firstIndex(where: { $0.id == item.id }) {
                switch result {
                case .success(let audio):
                    self.items[index].audio = audio
                case .failure(let error):
                    self.items[index].failed = true
                    self.onLog?("Röst: \(error.localizedDescription)")
                }
            }
            self.pump()
        }
    }

    private func produceAudio(_ text: String, config: VoiceConfig) async -> Result<Audio, Error> {
        let started = Date()
        let result = await produceAudioUncached(text, config: config)
        var fields: [String: Any] = [
            "text": text,
            "provider": config.provider.rawValue,
            "ms": Int(Date().timeIntervalSince(started) * 1000),
        ]
        switch result {
        case .success(.file(let url)): fields["result"] = "file"; fields["file"] = url.lastPathComponent
        case .success(.live): fields["result"] = "live"
        case .failure(let error): fields["result"] = "failed"; fields["error"] = error.localizedDescription
        }
        if config.provider == .system, let voice = SystemVoice.resolveVoice(config) {
            fields["voice"] = voice.name
            fields["voiceLanguage"] = voice.language
        }
        EventLog.shared.record("tts", fields)
        return result
    }

    private func produceAudioUncached(_ text: String, config: VoiceConfig) async -> Result<Audio, Error> {
        let url = cacheURL(for: text, config: config)
        if FileManager.default.fileExists(atPath: url.path) {
            return .success(.file(url))
        }
        switch config.provider {
        case .system:
            return await renderSystem(text, config: config, to: url)
        case .elevenLabs:
            let voice = ElevenLabsVoice(
                apiKey: config.elevenKey,
                voiceID: config.elevenVoiceID,
                modelID: config.elevenModel,
                languageCode: String(config.language.prefix(2)).lowercased()
            )
            do {
                try await voice.render(text, to: url)
                return .success(.file(url))
            } catch {
                // Keep talking with the built-in voice if the network or the key fails on stage.
                onLog?("\(error.localizedDescription) – använder macOS-rösten")
                var fallback = config
                fallback.provider = .system
                return await renderSystem(text, config: fallback, to: cacheURL(for: text, config: fallback))
            }
        }
    }

    private func renderSystem(_ text: String, config: VoiceConfig, to url: URL) async -> Result<Audio, Error> {
        if FileManager.default.fileExists(atPath: url.path) {
            return .success(.file(url))
        }
        guard system.renderingWorks else { return .success(.live) }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".caf")
        do {
            try await system.render(text, config: config, to: temporary)
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: temporary, to: url)
            return .success(.file(url))
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            system.renderingWorks = false
            onLog?("Kunde inte rendera macOS-rösten till fil (\(error.localizedDescription)) – spelar upp direkt i stället")
            return .success(.live)
        }
    }

    private func cacheURL(for text: String, config: VoiceConfig) -> URL {
        let key: String
        let ext: String
        switch config.provider {
        case .system:
            let voice = SystemVoice.resolveVoice(config)?.identifier ?? config.language
            key = "system|\(voice)|\(config.rate)|\(config.pitch)|\(text)"
            ext = "caf"
        case .elevenLabs:
            key = "eleven|\(config.elevenVoiceID)|\(config.elevenModel)|\(config.language)|\(text)"
            ext = "mp3"
        }
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheFolder.appendingPathComponent(String(digest.prefix(40))).appendingPathExtension(ext)
    }

    // MARK: Playback

    private func startPlayback(_ item: Item, _ audio: Audio) {
        onSubtitle?(item.text)
        stats = MouthStats()
        switch audio {
        case .file(let url):
            do {
                let newPlayer = try AVAudioPlayer(contentsOf: url)
                newPlayer.delegate = self
                newPlayer.isMeteringEnabled = true
                newPlayer.prepareToPlay()
                guard newPlayer.play() else { throw SpeechError.empty }
                player = newPlayer
                startMeter()
                EventLog.shared.record("speechStarted", ["text": item.text, "mode": "file", "duration": newPlayer.duration])
            } catch {
                EventLog.shared.record("speechError", ["text": item.text, "message": error.localizedDescription])
                onLog?("Kunde inte spela upp ljud: \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: url)
                items.removeFirst()
                pump()
            }
        case .live:
            playingLive = true
            startMeter()
            EventLog.shared.record("speechStarted", ["text": item.text, "mode": "live"])
            let gen = generation
            let config = self.config
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.system.speakLive(item.text, config: config)
                guard gen == self.generation, self.playingLive else { return }
                self.playingLive = false
                self.finishedCurrent()
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        Task { @MainActor [weak self] in self?.playerFinished(id) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let id = ObjectIdentifier(player)
        Task { @MainActor [weak self] in self?.playerFinished(id) }
    }

    private func playerFinished(_ id: ObjectIdentifier) {
        guard let current = player, ObjectIdentifier(current) == id else { return }
        player = nil
        finishedCurrent()
    }

    private func finishedCurrent() {
        if let finished = items.first {
            var fields = stats.fields
            fields["text"] = finished.text
            EventLog.shared.record("speechEnded", fields)
        }
        if !items.isEmpty { items.removeFirst() }
        if items.isEmpty {
            stopMeter()
            onSubtitle?(nil)
        }
        pump()
    }

    // MARK: Lip sync

    private func startMeter() {
        guard meterTask == nil else { return }
        meterTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 33_000_000)
                guard let self else { return }
                self.updateMouth()
            }
        }
    }

    private func stopMeter() {
        meterTask?.cancel()
        meterTask = nil
        mouth = 0
        onMouth?(0)
        EventLog.shared.record("mouthClosed")
    }

    private func updateMouth() {
        var target: Float = 0
        if let player, player.isPlaying {
            player.updateMeters()
            let power = player.averagePower(forChannel: 0) // dB, about -160...0
            target = max(0, min(1, (power + 40) / 30))
        } else if playingLive {
            // No audio levels when speaking directly: flap with the rhythm of the words.
            let t = Date().timeIntervalSinceReferenceDate
            let sinceWord = t - lastWordAt
            let envelope = sinceWord < 0.3 ? 1.0 : 0.45
            let wave = (sin(t * 21) * 0.5 + 0.5) * (sin(t * 7.7) * 0.3 + 0.7)
            target = Float(wave * envelope)
        }
        // Open fast, close a little slower.
        let speed: Float = target > mouth ? 0.75 : 0.35
        mouth += (target - mouth) * speed
        onMouth?(mouth)
        if player != nil || playingLive {
            stats.add(mouth)
        }
    }

    // MARK: Preparation

    /// Renders lines ahead of time so they play instantly (and work offline) on stage.
    func prepare(_ texts: [String]) async -> (rendered: Int, failed: Int) {
        let config = self.config
        var rendered = 0
        var failed = 0
        for text in texts {
            for sentence in SentenceSplitter.split(text) {
                switch await produceAudio(sentence, config: config) {
                case .success(.file(_)): rendered += 1
                default: failed += 1
                }
            }
        }
        return (rendered, failed)
    }
}
