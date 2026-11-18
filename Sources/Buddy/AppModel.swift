import AppKit
import Combine
import Foundation
import BuddyCore

struct LogEntry: Identifiable {
    let id = UUID()
    let time: Date
    let text: String
}

/// Fast-changing values for the control panel, kept apart so menus don't rebuild 10 times a second.
@MainActor
final class LiveState: ObservableObject {
    @Published var transcript = ""
    @Published var micLevel: Float = 0
    @Published var log: [LogEntry] = []
}

/// What the overlay shows.
@MainActor
final class AvatarState: ObservableObject {
    enum Mode: Equatable {
        case hidden, listening, thinking, speaking
    }

    @Published var mode: Mode = .hidden
    @Published var subtitle: String?
    /// 0...1, updated about 30 times a second while speaking. Read by the animation timeline.
    var mouth: CGFloat = 0
}

extension DirectorPhase {
    var label: String {
        switch self {
        case .paused: return "pausad"
        case .listening: return "lyssnar efter triggers"
        case .triggered: return "hörde sitt namn"
        case .thinking: return "tänker"
        case .speaking: return "pratar"
        case .awaitingReply: return "väntar på ditt svar"
        case .closing: return "säger hej då"
        }
    }
}

extension EndReason {
    var label: String {
        switch self {
        case .endPhrase: return "avslutsfras"
        case .lastTurn: return "sista repliken"
        case .timeout: return "tystnad"
        case .manual: return "manuellt"
        case .sessionChanged: return "presentationen ändrades"
        }
    }
}

/// Connects speech recognition, the dialog director, Claude and the voice.
@MainActor
final class AppModel: ObservableObject {
    let settings: AppSettings
    let store: SessionStore
    let avatar: AvatarState
    let live: LiveState
    let recognizer: SpeechRecognizer
    let player: SpeechPlayer
    let claude: ClaudeClient
    let director: Director

    @Published private(set) var phase: DirectorPhase = .paused
    @Published private(set) var activeSession: Session
    @Published private(set) var listening = false
    @Published private(set) var progressStamp = 0
    @Published private(set) var problem: String?

    private var micWanted = false
    private var testing = false
    private var cancellables: Set<AnyCancellable> = []
    private var tickTask: Task<Void, Never>?

    init() {
        let settings = AppSettings()
        let store = SessionStore()
        let session = store.session(withID: settings.activeSessionID) ?? store.sessions.first ?? Session.example()
        let player = SpeechPlayer()
        let claude = ClaudeClient()
        self.settings = settings
        self.store = store
        self.avatar = AvatarState()
        self.live = LiveState()
        self.recognizer = SpeechRecognizer()
        self.player = player
        self.claude = claude
        self.activeSession = session
        self.director = Director(session: session, settings: settings.directorSettings, brain: claude, voice: player)
        settings.activeSessionID = session.id.uuidString
        wire()
        applySettings()
    }

    private func wire() {
        director.onEvent = { [weak self] event in
            self?.handle(event)
        }
        recognizer.onTranscript = { [weak self] id, text in
            self?.heard(id: id, text: text)
        }
        recognizer.onLog = { [weak self] message in
            self?.addLog(message)
        }
        player.onLog = { [weak self] message in
            self?.addLog(message)
        }
        player.onSubtitle = { [weak self] text in
            self?.avatar.subtitle = text
        }
        player.onMouth = { [weak self] level in
            self?.avatar.mouth = CGFloat(level)
        }
        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applySettings()
            }
            .store(in: &cancellables)
    }

    // MARK: - Lifecycle

    func launch() {
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self else { return }
                self.director.tick()
                let level = self.recognizer.level
                if abs(level - self.live.micLevel) > 0.002 {
                    self.live.micLevel = level
                }
            }
        }
        addLog("Buddy startade. Aktiv presentation: \(activeSession.name)")
        if settings.anthropicKey.isEmpty {
            addLog("Tips: lägg in din Anthropic API-nyckel under Inställningar → AI.")
        }
        if settings.listenOnLaunch {
            Task { @MainActor in
                await self.setListening(true)
            }
        }
    }

    func shutdown() {
        tickTask?.cancel()
        recognizer.stop()
        player.stopSpeaking()
    }

    func applySettings() {
        director.settings = settings.directorSettings
        claude.apiKey = settings.anthropicKey
        claude.model = settings.claudeModel
        player.configure(voiceConfig)
    }

    var voiceConfig: VoiceConfig {
        VoiceConfig(
            provider: settings.voiceProvider,
            systemVoiceID: settings.systemVoiceID,
            rate: Float(settings.speechRate),
            pitch: Float(settings.speechPitch),
            language: settings.recognitionLocale,
            elevenKey: settings.elevenLabsKey,
            elevenVoiceID: settings.elevenLabsVoiceID,
            elevenModel: settings.elevenLabsModel
        )
    }

    // MARK: - Listening

    func setListening(_ on: Bool) async {
        if on {
            guard await ensurePermissions() else { return }
            listening = true
            director.start()
        } else {
            listening = false
            director.pause()
        }
    }

    func toggleListening() {
        Task { @MainActor in
            await self.setListening(!self.listening)
        }
    }

    private func ensurePermissions() async -> Bool {
        let mic = await SpeechRecognizer.requestMicrophonePermission()
        let speech = await SpeechRecognizer.requestSpeechPermission()
        if !mic {
            report("Buddy saknar tillgång till mikrofonen. Tillåt Buddy i Systeminställningar → Integritet och säkerhet → Mikrofon.")
            return false
        }
        if !speech {
            report("Buddy får inte använda taligenkänning. Tillåt Buddy i Systeminställningar → Integritet och säkerhet → Taligenkänning.")
            return false
        }
        problem = nil
        return true
    }

    private func report(_ message: String) {
        problem = message
        addLog(message)
    }

    private func setMicrophone(_ on: Bool) {
        micWanted = on
        if on {
            // Short pause so the tail of Buddy's own voice isn't picked up.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard let self, self.micWanted, !self.recognizer.isRunning else { return }
                self.recognizer.start(
                    locale: self.settings.recognitionLocale,
                    contextualStrings: self.vocabulary(),
                    preferOnDevice: self.settings.preferOnDevice
                )
            }
        } else {
            recognizer.stop()
            live.transcript = ""
        }
    }

    private func heard(id: Int, text: String) {
        guard !testing else { return }
        live.transcript = text
        director.hear(segment: id, text: text)
    }

    /// Words that help speech recognition: Buddy's name and every phrase in the presentation.
    private func vocabulary() -> [String] {
        let session = activeSession
        var words = [session.buddyName] + session.triggers + session.endPhrases
        for moment in session.moments where moment.enabled {
            words += moment.triggers + moment.endPhrases
        }
        var seen = Set<String>()
        return words.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    // MARK: - Dialog control

    func toggleMoment() {
        director.toggle()
    }

    func interrupt() {
        if testing {
            player.stopSpeaking()
        }
        director.interrupt()
    }

    func startMoment(_ id: UUID) {
        if phase.isActive { director.toggle() }
        director.queue(id)
        director.toggle()
    }

    func simulate(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        director.simulate(trimmed)
        recognizer.restartSegment()
    }

    func queueMoment(_ id: UUID?) {
        director.queue(id)
    }

    func resetProgress() {
        director.resetProgress()
    }

    func isCompleted(_ moment: Moment) -> Bool {
        director.completed.contains(moment.id)
    }

    var queuedMomentID: UUID? { director.queuedMomentID }
    var activeMoment: Moment? { director.activeMoment }

    /// Shows the avatar and says a test sentence.
    func testAvatar() {
        guard !phase.isActive, !testing else { return }
        testing = true
        updateAvatar()
        player.enqueue("Hej! Jag är \(activeSession.buddyName). Syns jag och hörs jag?")
        Task { @MainActor [weak self] in
            for _ in 0..<300 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self else { return }
                if !self.player.isBusy { break }
            }
            guard let self else { return }
            self.testing = false
            self.updateAvatar()
            self.recognizer.restartSegment()
        }
    }

    /// Sends a tiny request to check the API key and model.
    func testClaude() async -> String {
        let request = ReplyRequest(
            system: "Du testar en anslutning. Svara mycket kort på svenska.",
            messages: [ChatMessage(role: .user, text: "Säg hej på högst fem ord.")]
        )
        var reply = ""
        do {
            for try await chunk in claude.streamReply(request) {
                reply += chunk
            }
            return "Fungerar: \(reply.trimmingCharacters(in: .whitespacesAndNewlines))"
        } catch {
            return "Fel: \(error.localizedDescription)"
        }
    }

    /// Renders fixed lines ahead of time so they play instantly.
    func prepareLines() {
        let session = activeSession
        var texts = session.farewells + session.fallbackLines
        for moment in session.moments where moment.enabled {
            texts += moment.lines + moment.farewells
        }
        guard !texts.isEmpty else {
            addLog("Inga fasta repliker att förbereda")
            return
        }
        addLog("Förbereder \(texts.count) repliker…")
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.player.prepare(texts)
            var message = "Klart: \(result.rendered) ljudfiler förberedda"
            if result.failed > 0 { message += ", \(result.failed) kunde inte förberedas (spelas upp direkt)" }
            self.addLog(message)
        }
    }

    // MARK: - Sessions

    func activate(_ id: UUID) {
        guard let session = store.sessions.first(where: { $0.id == id }) else { return }
        settings.activeSessionID = id.uuidString
        activeSession = session
        director.updateSession(session)
        recognizer.setVocabulary(vocabulary())
        addLog("Aktiv presentation: \(session.name)")
    }

    func save(_ session: Session) {
        store.save(session)
        if session.id == activeSession.id {
            activeSession = session
            director.updateSession(session)
            recognizer.setVocabulary(vocabulary())
        }
    }

    func delete(_ id: UUID) {
        store.delete(id)
        if id == activeSession.id {
            let next = store.sessions.first ?? store.createNew()
            activate(next.id)
        }
    }

    // MARK: - Events

    private func handle(_ event: DirectorEvent) {
        switch event {
        case .phase(let newPhase):
            phase = newPhase
            updateAvatar()
        case .momentStarted(let moment):
            addLog("▶ \(moment.title)")
        case .momentEnded(let moment, let reason):
            addLog("■ \(moment.title) klart (\(reason.label))")
        case .microphone(let on):
            setMicrophone(on)
        case .presenterSaid(let text):
            addLog("Du: \(text)")
        case .buddySaid(let text):
            addLog("\(activeSession.buddyName): \(text)")
        case .progressChanged:
            progressStamp += 1
        case .log(let message):
            addLog(message)
        }
    }

    private func updateAvatar() {
        if testing {
            avatar.mode = .speaking
            return
        }
        switch phase {
        case .paused, .listening:
            avatar.mode = .hidden
        case .triggered, .awaitingReply:
            avatar.mode = .listening
        case .thinking:
            avatar.mode = .thinking
        case .speaking, .closing:
            avatar.mode = .speaking
        }
    }

    func addLog(_ text: String) {
        live.log.append(LogEntry(time: Date(), text: text))
        if live.log.count > 500 {
            live.log.removeFirst(live.log.count - 500)
        }
    }
}
