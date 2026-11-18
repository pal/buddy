import AVFoundation
import Foundation
import Speech

/// Shared between the audio thread and the main actor: forwards microphone buffers to the
/// current recognition request and keeps a smoothed input level.
final class AudioTapBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var level: Float = 0

    func setRequest(_ newRequest: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        request = newRequest
        lock.unlock()
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        let rms = AudioTapBox.rms(buffer)
        lock.lock()
        let current = request
        level = max(rms, level * 0.8)
        lock.unlock()
        current?.append(buffer)
    }

    func currentLevel() -> Float {
        lock.lock()
        defer { lock.unlock() }
        return level
    }

    static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count {
            sum += samples[i] * samples[i]
        }
        return (sum / Float(count)).squareRoot()
    }
}

/// Continuous speech recognition with Apple's Speech framework.
///
/// Each recognition task is a "segment" with an increasing id. Tasks are restarted when they
/// end, rotated at natural pauses (server recognition has a ~1 minute limit), and stopped while
/// Buddy speaks so it doesn't hear itself.
@MainActor
final class SpeechRecognizer {
    var onTranscript: ((Int, String) -> Void)?
    var onLog: ((String) -> Void)?

    private(set) var isRunning = false
    private(set) var isOnDevice = false

    private let engine = AVAudioEngine()
    private let box = AudioTapBox()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var taskCounter = 0
    private var activeTaskID: Int?
    private var taskStartedAt = Date()
    private var lastResultAt = Date()
    private var failures = 0
    private var watchdog: Task<Void, Never>?
    private var configObserver: NSObjectProtocol?

    private var localeID = "sv-SE"
    private var contextualStrings: [String] = []
    private var preferOnDevice = true

    var level: Float { isRunning ? box.currentLevel() : 0 }

    init() {
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            let target = self
            Task { @MainActor in target?.audioConfigurationChanged() }
        }
    }

    // MARK: - Permissions

    nonisolated static func requestSpeechPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    nonisolated static func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    // MARK: - Control

    func start(locale: String, contextualStrings: [String], preferOnDevice: Bool) {
        localeID = locale
        self.contextualStrings = Array(contextualStrings.prefix(100))
        self.preferOnDevice = preferOnDevice
        guard !isRunning else { return }

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)) else {
            onLog?("Taligenkänning stöds inte för språket \(locale)")
            return
        }
        guard recognizer.isAvailable else {
            onLog?("Taligenkänningen är inte tillgänglig just nu. Kontrollera nätverk och att Siri/diktering är på.")
            return
        }
        self.recognizer = recognizer

        do {
            try startEngine()
        } catch {
            onLog?("Kunde inte starta mikrofonen: \(error.localizedDescription)")
            return
        }
        isRunning = true
        failures = 0
        startTask()
        startWatchdog()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        watchdog?.cancel()
        watchdog = nil
        endTask()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// Phrases that bias recognition. Used from the next recognition task.
    func setVocabulary(_ strings: [String]) {
        contextualStrings = Array(strings.prefix(100))
    }

    /// Starts a new segment (e.g. after simulated input).
    func restartSegment() {
        guard isRunning else { return }
        endTask()
        startTask()
    }

    // MARK: - Engine

    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "Buddy", code: 1, userInfo: [NSLocalizedDescriptionKey: "Ingen mikrofon hittades"])
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: SpeechRecognizer.tapBlock(box))
        engine.prepare()
        try engine.start()
    }

    /// Built outside the main actor: the block runs on the audio thread.
    nonisolated private static func tapBlock(_ box: AudioTapBox) -> AVAudioNodeTapBlock {
        return { buffer, _ in
            box.process(buffer)
        }
    }

    private func audioConfigurationChanged() {
        guard isRunning else { return }
        onLog?("Ljudenheten ändrades – startar om mikrofonen")
        stop()
        start(locale: localeID, contextualStrings: contextualStrings, preferOnDevice: preferOnDevice)
    }

    // MARK: - Recognition tasks

    private func startTask() {
        guard isRunning, let recognizer else { return }
        taskCounter += 1
        let id = taskCounter
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.contextualStrings = contextualStrings
        request.addsPunctuation = true
        if preferOnDevice, recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        isOnDevice = request.requiresOnDeviceRecognition
        self.request = request
        box.setRequest(request)
        activeTaskID = id
        taskStartedAt = Date()
        lastResultAt = Date()
        task = recognizer.recognitionTask(with: request, resultHandler: SpeechRecognizer.resultHandler(id: id, owner: self))
    }

    private func endTask() {
        box.setRequest(nil)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        activeTaskID = nil
    }

    /// Built outside the main actor: Speech calls it on its own queue.
    nonisolated private static func resultHandler(
        id: Int,
        owner: SpeechRecognizer
    ) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        return { [weak owner] result, error in
            let target = owner
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let message = error.map { ($0 as NSError).localizedDescription }
            let code = error.map { ($0 as NSError).code }
            Task { @MainActor in
                target?.handle(id: id, text: text, isFinal: isFinal, error: message, code: code)
            }
        }
    }

    private func handle(id: Int, text: String?, isFinal: Bool, error: String?, code: Int?) {
        guard isRunning, id == activeTaskID else { return }
        if let text, !text.isEmpty {
            lastResultAt = Date()
            failures = 0
            onTranscript?(id, text)
        }
        guard isFinal || error != nil else { return }

        // The task is over: start the next one. "No speech detected" (1110) is routine.
        endTask()
        var delay: Double = 0.05
        if let error, code != 1110, code != 216, code != 301 {
            failures += 1
            delay = min(8, 0.5 * pow(2, Double(min(failures, 4))))
            onLog?("Taligenkänning: \(error) – försöker igen")
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, self.isRunning, self.activeTaskID == nil else { return }
            self.startTask()
        }
    }

    /// Rotates long tasks at natural pauses and before the server-side time limit.
    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self else { return }
                guard self.isRunning, self.activeTaskID != nil else { continue }
                let age = Date().timeIntervalSince(self.taskStartedAt)
                let quiet = Date().timeIntervalSince(self.lastResultAt)
                let softLimit: TimeInterval = self.isOnDevice ? 240 : 45
                let hardLimit: TimeInterval = self.isOnDevice ? 600 : 55
                if (age > softLimit && quiet > 1.0) || age > hardLimit {
                    self.restartSegment()
                }
            }
        }
    }
}
