import AVFoundation
import CryptoKit
import Foundation
import BuddyCore

/// How often the mouth is updated, and the length of the audio windows it follows.
private enum MouthTiming {
    static let meterInterval = 1.0 / 30.0
    static let envelopeWindow = 0.02
    /// Syllables per second used to shape the mouth within a word.
    static let syllableRate = 4.0
}

/// Plays Buddy's sentences in order. Renders the next sentence while the current one plays,
/// caches rendered audio on disk, and reports a mouth-opening level for lip sync.
@MainActor
final class SpeechPlayer: NSObject, VoiceOutput, AVAudioPlayerDelegate {
    var onSubtitle: ((String?) -> Void)?
    var onMouth: ((Float) -> Void)?
    var onLog: ((String) -> Void)?
    /// After each request to ElevenLabs: nil if it worked, otherwise why it did not.
    var onElevenLabs: ((String?) -> Void)?

    let system: SystemVoice
    private(set) var config = VoiceConfig()

    private enum Audio {
        case file(URL)
        case live
    }

    private struct Item {
        let id: Int
        /// The sentence as the director gave it, possibly with audio tags.
        let text: String
        let kind: SpeechKind
        var audio: Audio?
        var failed = false
        /// Mouth opening per 20 ms of the rendered audio, so the mouth follows the syllables.
        var envelope: [Float] = []
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
        /// How many times the mouth opened (with hysteresis), roughly one per syllable.
        var openings = 0
        private var isOpen = false

        mutating func add(_ level: Float) {
            samples += 1
            sum += level
            max = Swift.max(max, level)
            if level > 0.15 { open += 1 }
            if !isOpen, level > 0.45 {
                isOpen = true
                openings += 1
            } else if isOpen, level < 0.2 {
                isOpen = false
            }
        }

        var fields: [String: Any] {
            [
                "samples": samples,
                "seconds": Double(samples) * MouthTiming.meterInterval,
                "maxMouth": Double(max),
                "meanMouth": samples == 0 ? 0 : Double(sum / Float(samples)),
                "openFraction": samples == 0 ? 0 : Double(open) / Double(samples),
                "openings": openings,
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

    func enqueue(_ sentence: String, kind: SpeechKind) {
        let text = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        // A sentence that is only an audio tag has nothing to say for voices without tags.
        guard !text.isEmpty, config.speaksAudioTags || !AudioTags.strip(text).isEmpty else { return }
        counter += 1
        items.append(Item(id: counter, text: text, kind: kind))
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
            let result = await self.produceAudio(item.text, kind: item.kind, config: config)
            guard gen == self.generation else { return }
            self.rendering = false
            if let index = self.items.firstIndex(where: { $0.id == item.id }) {
                switch result {
                case .success(let audio):
                    self.items[index].audio = audio
                    if case .file(let url) = audio {
                        self.items[index].envelope = SpeechPlayer.envelope(of: url)
                    }
                case .failure(let error):
                    self.items[index].failed = true
                    self.onLog?("Röst: \(error.localizedDescription)")
                }
            }
            self.pump()
        }
    }

    private func produceAudio(
        _ text: String,
        kind: SpeechKind,
        config: VoiceConfig,
        preparing: Bool = false
    ) async -> Result<Audio, Error> {
        let started = Date()
        var fields: [String: Any] = [
            "text": AudioTags.strip(text),
            "kind": kind.rawValue,
            "provider": config.provider.rawValue,
        ]
        let result: Result<Audio, Error>
        switch config.provider {
        case .system:
            result = await systemAudio(text, config: config, fields: &fields)
        case .elevenLabs:
            result = await elevenLabsAudio(text, kind: kind, config: config, preparing: preparing, fields: &fields)
        }
        fields["ms"] = Int(Date().timeIntervalSince(started) * 1000)
        switch result {
        case .success(.file(let url)): fields["result"] = "file"; fields["file"] = url.lastPathComponent
        case .success(.live): fields["result"] = "live"
        case .failure(let error): fields["result"] = "failed"; fields["error"] = error.localizedDescription
        }
        EventLog.shared.record("tts", fields)
        return result
    }

    /// macOS voice. Audio tags would be read aloud, so they are removed.
    private func systemAudio(_ text: String, config: VoiceConfig, fields: inout [String: Any]) async -> Result<Audio, Error> {
        let spoken = AudioTags.strip(text)
        fields["spoken"] = spoken
        let voice = SystemVoice.resolveVoice(config)
        if let voice {
            fields["voice"] = voice.name
            fields["voiceLanguage"] = voice.language
        }
        guard !spoken.isEmpty else { return .failure(SpeechError.empty) }
        let base = cacheBase("system|\(voice?.identifier ?? config.language)|\(config.rate)|\(config.pitch)|\(spoken)")
        if let cached = cachedFile(base) {
            fields["cached"] = true
            return .success(.file(cached))
        }
        fields["cached"] = false
        return await renderSystem(spoken, config: config, to: base.appendingPathExtension("caf"))
    }

    /// ElevenLabs. Fixed lines prepared ahead of time use the best model and play from the
    /// cache; everything else is rendered with the selected model. Falls back to the macOS
    /// voice if ElevenLabs fails, so Buddy keeps talking on stage.
    private func elevenLabsAudio(
        _ text: String,
        kind: SpeechKind,
        config: VoiceConfig,
        preparing: Bool,
        fields: inout [String: Any]
    ) async -> Result<Audio, Error> {
        let selected = config.elevenModel
        let best = config.elevenPreparedQuality ? ElevenLabsAPI.preparedModel(for: selected) : selected
        func spoken(_ model: String) -> String {
            config.elevenAudioTags && ElevenLabsAPI.supportsAudioTags(model) ? text : AudioTags.strip(text)
        }
        var models = [selected]
        if kind == .fixed, best != selected {
            models = preparing ? [best] : [best, selected]
        }
        for model in models {
            if let cached = cachedFile(elevenLabsBase(spoken(model), model: model, config: config)) {
                fields["model"] = model
                fields["spoken"] = spoken(model)
                fields["cached"] = true
                return .success(.file(cached))
            }
        }
        let model = preparing ? models[0] : selected
        let sentence = spoken(model)
        fields["model"] = model
        fields["spoken"] = sentence
        fields["cached"] = false
        guard !sentence.isEmpty else { return .failure(SpeechError.empty) }
        do {
            let client = ElevenLabsClient(apiKey: config.elevenKey)
            let audio = try await client.speech(
                sentence,
                voiceID: config.elevenVoiceID,
                model: model,
                languageCode: ElevenLabsAPI.languageCode(locale: config.language)
            )
            let url = elevenLabsBase(sentence, model: model, config: config).appendingPathExtension(audio.fileExtension)
            try audio.data.write(to: url, options: .atomic)
            onElevenLabs?(nil)
            return .success(.file(url))
        } catch {
            // Keep talking with the built-in voice if the network or the key fails on stage.
            onLog?("\(error.localizedDescription) – använder macOS-rösten")
            onElevenLabs?(error.localizedDescription)
            fields["fallback"] = true
            fields["elevenLabsError"] = error.localizedDescription
            fields["provider"] = VoiceProvider.system.rawValue
            var fallback = config
            fallback.provider = .system
            return await systemAudio(text, config: fallback, fields: &fields)
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

    // MARK: Cache

    /// Cache file path without extension; the extension depends on the audio format.
    private func cacheBase(_ key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheFolder.appendingPathComponent(String(digest.prefix(40)))
    }

    private func elevenLabsBase(_ spoken: String, model: String, config: VoiceConfig) -> URL {
        let language = ElevenLabsAPI.languageCode(locale: config.language)
        return cacheBase("eleven|\(config.elevenVoiceID)|\(model)|\(language)|\(spoken)")
    }

    private func cachedFile(_ base: URL) -> URL? {
        for ext in ["mp3", "wav", "caf", "aac"] {
            let url = base.appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    // MARK: Playback

    private func startPlayback(_ item: Item, _ audio: Audio) {
        let subtitle = AudioTags.strip(item.text)
        onSubtitle?(subtitle.isEmpty ? nil : subtitle)
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
                EventLog.shared.record("speechStarted", [
                    "text": subtitle, "spoken": item.text, "mode": "file", "duration": newPlayer.duration,
                ])
            } catch {
                EventLog.shared.record("speechError", ["text": subtitle, "message": error.localizedDescription])
                onLog?("Kunde inte spela upp ljud: \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: url)
                items.removeFirst()
                pump()
            }
        case .live:
            playingLive = true
            startMeter()
            EventLog.shared.record("speechStarted", ["text": subtitle, "spoken": item.text, "mode": "live"])
            let gen = generation
            let config = self.config
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.system.speakLive(subtitle, config: config)
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
            fields["text"] = AudioTags.strip(finished.text)
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
                try? await Task.sleep(nanoseconds: UInt64(MouthTiming.meterInterval * 1_000_000_000))
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
            if let envelope = items.first?.envelope, !envelope.isEmpty {
                // A little ahead of the audio, since drawing the frame takes a moment.
                let index = Int((player.currentTime + 0.03) / MouthTiming.envelopeWindow)
                target = index < envelope.count ? envelope[index] : 0
            } else {
                player.updateMeters()
                let power = player.averagePower(forChannel: 0) // dB, about -160...0
                target = max(0, min(1, (power + 40) / 30))
            }
        } else if playingLive {
            // No audio levels when speaking directly: flap with the rhythm of the words.
            let t = Date().timeIntervalSinceReferenceDate
            let sinceWord = t - lastWordAt
            let envelope = sinceWord < 0.3 ? 1.0 : 0.45
            let wave = (sin(t * 21) * 0.5 + 0.5) * (sin(t * 7.7) * 0.3 + 0.7)
            target = Float(wave * envelope)
        }
        // Open fast, close a little slower.
        let speed: Float = target > mouth ? 0.75 : 0.7
        mouth += (target - mouth) * speed
        onMouth?(mouth)
        if player != nil || playingLive {
            stats.add(mouth)
        }
    }

    /// Mouth opening per 20 ms of an audio file. The mouth opens when there is sound and
    /// closes in the pauses between words. Synthetic voices are nearly equally loud through a
    /// word, so within a word the opening is shaped at a syllable-like rhythm that restarts at
    /// every word onset.
    static func envelope(of url: URL) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url) else { return [] }
        let format = file.processingFormat
        let length = AVAudioFrameCount(file.length)
        guard length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: length),
              (try? file.read(into: buffer)) != nil,
              let samples = buffer.floatChannelData?[0]
        else { return [] }
        let count = Int(buffer.frameLength)
        let hop = max(1, Int(format.sampleRate * MouthTiming.envelopeWindow))
        var loudness: [Float] = []
        var start = 0
        while start < count {
            let end = min(count, start + hop)
            var sum: Float = 0
            for i in start..<end {
                sum += samples[i] * samples[i]
            }
            let rms = (sum / Float(end - start)).squareRoot()
            loudness.append(20 * log10(max(rms, 0.000_001)))
            start = end
        }
        guard !loudness.isEmpty else { return [] }
        let sorted = loudness.sorted()
        let loud = sorted[Int(Float(sorted.count - 1) * 0.95)]
        var mouth: [Float] = []
        mouth.reserveCapacity(loudness.count)
        var quiet = true
        var onset = 0
        for (index, level) in loudness.enumerated() {
            let energy = max(0, min(1, (level - (loud - 12)) / 10))
            if quiet, energy > 0.5 {
                quiet = false
                onset = index
            } else if !quiet, energy < 0.25 {
                quiet = true
            }
            if quiet {
                mouth.append(energy)
            } else {
                let t = Double(index - onset) * MouthTiming.envelopeWindow
                mouth.append(energy * Float(abs(cos(Double.pi * MouthTiming.syllableRate * t))))
            }
        }
        return mouth
    }

    // MARK: Preparation

    /// Renders fixed lines ahead of time so they play instantly (and work offline) on stage.
    /// With ElevenLabs they are rendered with the best model, since waiting doesn't matter here.
    func prepare(_ texts: [String]) async -> (rendered: Int, failed: Int) {
        let config = self.config
        var rendered = 0
        var failed = 0
        for text in texts {
            for sentence in SentenceSplitter.split(text) {
                switch await produceAudio(sentence, kind: .fixed, config: config, preparing: true) {
                case .success(.file(_)): rendered += 1
                default: failed += 1
                }
            }
        }
        return (rendered, failed)
    }
}
