import AVFoundation
import Foundation

enum SpeechError: LocalizedError {
    case empty
    case setup(String)
    case http(String)

    var errorDescription: String? {
        switch self {
        case .empty: return "Talsyntesen gav inget ljud"
        case .setup(let message): return message
        case .http(let message): return message
        }
    }
}

/// Voice settings used when rendering a sentence.
struct VoiceConfig: Equatable {
    var provider: VoiceProvider = .system
    var systemVoiceID = ""
    var rate: Float = 0.5
    var pitch: Float = 1.2
    var language = "sv-SE"
    var elevenKey = ""
    var elevenVoiceID = ""
    var elevenModel = "eleven_flash_v2_5"
}

/// Collects AVSpeechSynthesizer output buffers into an audio file.
final class BufferFileWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private var file: AVAudioFile?
    private var frames: AVAudioFramePosition = 0
    private var continuation: CheckedContinuation<Void, Error>?
    private var done = false

    init(url: URL) {
        self.url = url
    }

    func attach(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func handle(_ buffer: AVAudioBuffer) {
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        if pcm.frameLength == 0 {
            finish()
            return
        }
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        do {
            if file == nil {
                file = try AVAudioFile(
                    forWriting: url,
                    settings: pcm.format.settings,
                    commonFormat: pcm.format.commonFormat,
                    interleaved: pcm.format.isInterleaved
                )
            }
            try file?.write(from: pcm)
            frames += AVAudioFramePosition(pcm.frameLength)
        } catch {
            NSLog("Buddy: kunde inte skriva ljud: \(error)")
        }
    }

    /// Closes the file and reports the result. Safe to call more than once.
    func finish() {
        lock.lock()
        guard !done else {
            lock.unlock()
            return
        }
        done = true
        let continuation = self.continuation
        self.continuation = nil
        let succeeded = frames > 0
        file = nil // closes the file
        lock.unlock()
        if succeeded {
            continuation?.resume()
        } else {
            continuation?.resume(throwing: SpeechError.empty)
        }
    }
}

/// Writers for utterances being rendered, looked up from synthesizer delegate callbacks.
final class WriterRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var writers: [ObjectIdentifier: BufferFileWriter] = [:]

    func add(_ writer: BufferFileWriter, for utterance: AVSpeechUtterance) {
        lock.lock()
        writers[ObjectIdentifier(utterance)] = writer
        lock.unlock()
    }

    func remove(_ id: ObjectIdentifier) -> BufferFileWriter? {
        lock.lock()
        defer { lock.unlock() }
        return writers.removeValue(forKey: id)
    }

    func removeAll() -> [BufferFileWriter] {
        lock.lock()
        defer { lock.unlock() }
        let all = Array(writers.values)
        writers.removeAll()
        return all
    }
}

/// macOS's built-in voices. Renders to a file (so the mouth can follow the real audio level)
/// and falls back to speaking directly if rendering doesn't work on this system.
@MainActor
final class SystemVoice: NSObject, AVSpeechSynthesizerDelegate {
    private let renderer = AVSpeechSynthesizer()
    private let live: AVSpeechSynthesizer
    private let liveID: ObjectIdentifier
    private let registry = WriterRegistry()
    private var liveContinuation: CheckedContinuation<Void, Never>?

    /// Set to false after a failed render; from then on sentences are spoken directly.
    var renderingWorks = true
    /// Called at each word while speaking directly (drives the mouth animation).
    var onWord: (() -> Void)?

    override init() {
        let liveSynth = AVSpeechSynthesizer()
        live = liveSynth
        liveID = ObjectIdentifier(liveSynth)
        super.init()
        renderer.delegate = self
        live.delegate = self
    }

    // MARK: Voices

    static func voices(for language: String) -> [AVSpeechSynthesisVoice] {
        let prefix = String(language.prefix(2)).lowercased()
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().hasPrefix(prefix) }
            .sorted { a, b in
                if a.quality.rawValue != b.quality.rawValue { return a.quality.rawValue > b.quality.rawValue }
                return a.name < b.name
            }
    }

    static func qualityLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium: return "premium"
        case .enhanced: return "förbättrad"
        default: return "standard"
        }
    }

    static func resolveVoice(_ config: VoiceConfig) -> AVSpeechSynthesisVoice? {
        if !config.systemVoiceID.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: config.systemVoiceID) {
            return voice
        }
        return voices(for: config.language).first ?? AVSpeechSynthesisVoice(language: config.language)
    }

    private func makeUtterance(_ text: String, _ config: VoiceConfig) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = SystemVoice.resolveVoice(config)
        utterance.rate = max(AVSpeechUtteranceMinimumSpeechRate, min(AVSpeechUtteranceMaximumSpeechRate, config.rate))
        utterance.pitchMultiplier = max(0.5, min(2.0, config.pitch))
        return utterance
    }

    // MARK: Rendering

    func render(_ text: String, config: VoiceConfig, to url: URL) async throws {
        let utterance = makeUtterance(text, config)
        let writer = BufferFileWriter(url: url)
        registry.add(writer, for: utterance)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writer.attach(continuation)
            renderer.write(utterance, toBufferCallback: SystemVoice.bufferCallback(writer))
            DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
                writer.finish()
            }
        }
    }

    func cancelRendering() {
        if renderer.isSpeaking {
            renderer.stopSpeaking(at: .immediate)
        }
        for writer in registry.removeAll() {
            writer.finish()
        }
    }

    nonisolated private static func bufferCallback(_ writer: BufferFileWriter) -> AVSpeechSynthesizer.BufferCallback {
        return { buffer in
            writer.handle(buffer)
        }
    }

    // MARK: Speaking directly

    func speakLive(_ text: String, config: VoiceConfig) async {
        stopLive()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            liveContinuation = continuation
            live.speak(makeUtterance(text, config))
        }
    }

    func stopLive() {
        if live.isSpeaking {
            live.stopSpeaking(at: .immediate)
        }
        liveEnded()
    }

    private func liveEnded() {
        let continuation = liveContinuation
        liveContinuation = nil
        continuation?.resume()
    }

    private func wordSpoken() {
        onWord?()
    }

    // MARK: AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        ended(synthesizer, utterance)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        ended(synthesizer, utterance)
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        guard ObjectIdentifier(synthesizer) == liveID else { return }
        Task { @MainActor [weak self] in self?.wordSpoken() }
    }

    nonisolated private func ended(_ synthesizer: AVSpeechSynthesizer, _ utterance: AVSpeechUtterance) {
        if ObjectIdentifier(synthesizer) == liveID {
            Task { @MainActor [weak self] in self?.liveEnded() }
        } else if let writer = registry.remove(ObjectIdentifier(utterance)) {
            // Give the last buffers a moment to arrive before closing the file.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                writer.finish()
            }
        }
    }
}

/// ElevenLabs text-to-speech (https://elevenlabs.io). Returns MP3 audio.
struct ElevenLabsVoice {
    let apiKey: String
    let voiceID: String
    let modelID: String
    let languageCode: String

    func render(_ text: String, to url: URL) async throws {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let voice = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw SpeechError.setup("ElevenLabs-nyckel saknas (Inställningar → Röst)") }
        guard !voice.isEmpty,
              let encoded = voice.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              var components = URLComponents(string: "https://api.elevenlabs.io/v1/text-to-speech/\(encoded)")
        else { throw SpeechError.setup("Ange ett röst-id för ElevenLabs (Inställningar → Röst)") }
        components.queryItems = [URLQueryItem(name: "output_format", value: "mp3_44100_128")]
        guard let endpoint = components.url else { throw SpeechError.setup("Ogiltigt röst-id") }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        var body: [String: Any] = ["text": text, "model_id": modelID]
        // Only the v2.5 models accept a forced language.
        if modelID.contains("v2_5"), !languageCode.isEmpty {
            body["language_code"] = languageCode
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, !data.isEmpty else {
            let detail = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw SpeechError.http("ElevenLabs svarade \(status): \(detail)")
        }
        try data.write(to: url, options: .atomic)
    }
}
