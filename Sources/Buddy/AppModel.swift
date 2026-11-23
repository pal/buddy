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
        case .paused: return "lyssnar inte"
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
    /// The microphone, or a test inbox in the end-to-end tests.
    let input: SpeechInput
    let player: SpeechPlayer
    let claude: ClaudeClient
    let director: Director

    @Published private(set) var phase: DirectorPhase = .paused
    @Published private(set) var activeSession: Session
    @Published private(set) var listening = false
    @Published private(set) var progressStamp = 0
    @Published private(set) var problem: String?
    /// Selected pane in the settings window (remembered), and whether the voice picker is open.
    @Published var settingsTab: SettingsTab = .voice {
        didSet { settings.lastSettingsTab = settingsTab.rawValue }
    }
    @Published var voicePickerOpen = false
    /// Opens the settings window (set by the window manager).
    var showSettingsWindow: (() -> Void)?
    /// End-to-end test of the editing shortcuts in the settings window (set by the window manager).
    var testEditShortcuts: (() -> Void)?
    let updater: Updater
    /// Last time Buddy heard, said or was asked to do something (updates wait for a quiet spell).
    private(set) var lastActivityAt = Date()

    private var micWanted = false
    private var testing = false
    /// Voice Library voices from the latest listing (used by the end-to-end test commands).
    private var lastLibraryVoices: [ElevenLabsAPI.Voice] = []
    private var cancellables: Set<AnyCancellable> = []
    private var tickTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?
    private let options = LaunchOptions.current
    private let commandReader: LineFileReader?

    init() {
        let options = LaunchOptions.current
        let settings = AppSettings()
        let store = SessionStore()
        var session = store.session(withID: settings.activeSessionID) ?? store.sessions.first ?? Session.example()
        if let file = options.sessionFile {
            do {
                session = try store.importFile(at: file)
            } catch {
                NSLog("Buddy: kunde inte läsa \(file.path): \(error)")
                EventLog.shared.record("error", ["message": "session file: \(error.localizedDescription)"])
            }
        }
        let player = SpeechPlayer()
        let claude = ClaudeClient()
        if let url = options.claudeURL {
            claude.endpoint = url
        }
        self.settings = settings
        self.updater = Updater(settings: settings)
        self.store = store
        self.avatar = AvatarState()
        self.live = LiveState()
        if let inbox = options.inbox {
            self.input = InboxInput(url: inbox)
        } else {
            self.input = SpeechRecognizer()
        }
        self.commandReader = options.commands.map { LineFileReader(url: $0) }
        self.player = player
        self.claude = claude
        self.activeSession = session
        self.director = Director(session: session, settings: settings.directorSettings, brain: claude, voice: player)
        settings.activeSessionID = session.id.uuidString
        settingsTab = SettingsTab(rawValue: settings.lastSettingsTab) ?? .voice
        wire()
        applySettings()
    }

    private func wire() {
        director.onEvent = { [weak self] event in
            self?.handle(event)
        }
        updater.isBusy = { [weak self] in self?.isBusyForUpdate ?? true }
        updater.lastActivity = { [weak self] in self?.lastActivityAt ?? Date() }
        updater.quitApp = { [weak self] in self?.quit() }
        input.onTranscript = { [weak self] id, text in
            self?.heard(id: id, text: text)
        }
        input.onLog = { [weak self] message in
            self?.addLog(message)
        }
        if let inbox = input as? InboxInput {
            inbox.onCommand = { [weak self] command in
                self?.perform(command)
            }
        }
        player.onLog = { [weak self] message in
            self?.addLog(message)
        }
        player.onSubtitle = { [weak self] text in
            self?.avatar.subtitle = text
            EventLog.shared.record("subtitle", ["text": text.map { $0 as Any } ?? NSNull()])
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
                let level = self.input.level
                self.director.audioLevel(level)
                self.director.tick()
                if abs(level - self.live.micLevel) > 0.002 {
                    self.live.micLevel = level
                }
                if let reader = self.commandReader {
                    for object in reader.readNewObjects() {
                        if let command = LineFileReader.command(from: object) {
                            self.perform(command)
                        }
                    }
                }
            }
        }
        addLog("Buddy startade. Aktiv presentation: \(activeSession.name)")
        updater.start()
        updateTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                self?.updater.maybeInstall()
            }
        }
        if settings.anthropicKey.isEmpty {
            addLog("Tips: lägg in din Anthropic API-nyckel under Inställningar → AI.")
        }
        if settings.listeningOn {
            Task { @MainActor in
                await self.setListening(true, remember: false)
            }
        } else {
            addLog("Lyssnandet är avstängt. Slå på det i menyn eller med ⌃⌥⌘L.")
            EventLog.shared.record("listening", ["on": false, "remembered": true])
        }
    }

    func shutdown() {
        tickTask?.cancel()
        input.stop()
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
            elevenModel: settings.elevenLabsModel,
            elevenAudioTags: settings.elevenLabsAudioTags,
            elevenPreparedQuality: settings.elevenLabsPreparedQuality
        )
    }

    // MARK: - Listening

    /// Turns listening on or off. A choice by the user is remembered, also across restarts and
    /// updates. Off means the microphone is not used at all.
    func setListening(_ on: Bool, remember: Bool = true) async {
        if remember {
            settings.listeningOn = on
        }
        if on {
            guard await ensurePermissions() else { return }
            listening = true
            director.start()
        } else {
            listening = false
            director.pause()
        }
        EventLog.shared.record("listening", ["on": listening])
    }

    func toggleListening() {
        Task { @MainActor in
            await self.setListening(!self.listening)
        }
    }

    private func ensurePermissions() async -> Bool {
        if input is InboxInput {
            // Test input needs neither the microphone nor speech recognition.
            EventLog.shared.record("permissions", ["skipped": true])
            return true
        }
        EventLog.shared.record("permissions", ["before": SpeechRecognizer.permissionSummary()])
        let mic = await SpeechRecognizer.requestMicrophonePermission()
        let speech = await SpeechRecognizer.requestSpeechPermission()
        EventLog.shared.record("permissions", ["microphone": mic, "speech": speech])
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
                guard let self, self.micWanted, !self.input.isRunning else { return }
                self.input.start(
                    locale: self.settings.recognitionLocale,
                    contextualStrings: self.vocabulary(),
                    preferOnDevice: self.settings.preferOnDevice
                )
            }
        } else {
            input.stop()
            live.transcript = ""
        }
    }

    private func heard(id: Int, text: String) {
        guard !testing else { return }
        lastActivityAt = Date()
        EventLog.shared.record("transcript", ["segment": id, "text": text])
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
        input.restartSegment()
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
        player.enqueue("Hej! Jag är \(activeSession.buddyName). Syns jag och hörs jag?", kind: .live)
        Task { @MainActor [weak self] in
            for _ in 0..<300 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self else { return }
                if !self.player.isBusy { break }
            }
            guard let self else { return }
            self.testing = false
            self.updateAvatar()
            self.input.restartSegment()
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
            EventLog.shared.record("prepared", ["rendered": result.rendered, "failed": result.failed])
        }
    }

    /// Quits Buddy. An open sheet, such as the voice picker, would otherwise stop macOS
    /// from quitting the app, so sheets are closed first.
    func quit() {
        updater.installOnQuitIfReady()
        voicePickerOpen = false
        var closedSheet = false
        for window in NSApp.windows {
            if let sheet = window.attachedSheet {
                window.endSheet(sheet)
                closedSheet = true
            }
        }
        guard closedSheet else {
            NSApp.terminate(nil)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
        }
    }

    /// Installing an update now would disturb: a dialog, speech, or one of Buddy's windows is open.
    var isBusyForUpdate: Bool {
        director.activeMoment != nil || player.isBusy || testing || voicePickerOpen
            || NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) }
    }

    // MARK: - ElevenLabs voices

    private var elevenLabsClient: ElevenLabsClient { ElevenLabsClient(apiKey: settings.elevenLabsKey) }

    /// Voices in the ElevenLabs Voice Library for the presentation language.
    func elevenLabsLibraryVoices() async throws -> [ElevenLabsAPI.Voice] {
        let voices = try await elevenLabsClient.libraryVoices(language: ElevenLabsAPI.languageCode(locale: settings.recognitionLocale))
        lastLibraryVoices = voices
        return voices
    }

    func elevenLabsMyVoices() async throws -> [ElevenLabsAPI.Voice] {
        try await elevenLabsClient.myVoices()
    }

    /// Makes a voice Buddy's voice. Library voices are added to "My voices" first.
    func useElevenLabsVoice(_ voice: ElevenLabsAPI.Voice, fromLibrary: Bool) async throws {
        var id = voice.id
        if fromLibrary {
            id = try await elevenLabsClient.addLibraryVoice(voice)
        }
        settings.elevenLabsVoiceID = id
        settings.elevenLabsVoiceName = voice.name
        addLog("Röst för Buddy: \(voice.name)")
        EventLog.shared.record("elevenLabsVoiceSelected", ["voiceID": id, "name": voice.name, "fromLibrary": fromLibrary])
    }

    private func listElevenLabsVoicesForTest() {
        Task { @MainActor in
            var fields: [String: Any] = [:]
            do {
                let library = try await self.elevenLabsLibraryVoices()
                fields["library"] = library.map(\.name)
                fields["libraryIDs"] = library.map(\.id)
                fields["mine"] = try await self.elevenLabsMyVoices().map(\.name)
            } catch {
                fields["error"] = error.localizedDescription
            }
            EventLog.shared.record("elevenLabsVoices", fields)
        }
    }

    private func useLibraryVoiceForTest(id: String) {
        Task { @MainActor in
            guard let voice = self.lastLibraryVoices.first(where: { $0.id == id }) else {
                EventLog.shared.record("error", ["message": "no library voice \(id)"])
                return
            }
            do {
                try await self.useElevenLabsVoice(voice, fromLibrary: true)
            } catch {
                EventLog.shared.record("error", ["message": error.localizedDescription])
            }
        }
    }

    // MARK: - Sessions

    func activate(_ id: UUID) {
        guard let session = store.sessions.first(where: { $0.id == id }) else { return }
        settings.activeSessionID = id.uuidString
        activeSession = session
        director.updateSession(session)
        input.setVocabulary(vocabulary())
        addLog("Aktiv presentation: \(session.name)")
    }

    func save(_ session: Session) {
        store.save(session)
        if session.id == activeSession.id {
            activeSession = session
            director.updateSession(session)
            input.setVocabulary(vocabulary())
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
        let log = EventLog.shared
        switch event {
        case .phase(let newPhase):
            phase = newPhase
            if newPhase != .listening && newPhase != .paused {
                lastActivityAt = Date()
            }
            log.record("phase", ["phase": newPhase.rawValue])
            updateAvatar()
        case .momentStarted(let moment):
            log.record("momentStarted", ["title": moment.title, "mode": moment.mode.rawValue])
            addLog("▶ \(moment.title)")
        case .momentEnded(let moment, let reason):
            log.record("momentEnded", ["title": moment.title, "reason": reason.rawValue])
            addLog("■ \(moment.title) klart (\(reason.label))")
        case .heard(let phrase, let kind):
            log.record("heard", ["phrase": phrase, "kind": kind.rawValue])
        case .microphone(let on):
            log.record("microphone", ["on": on])
            setMicrophone(on)
        case .presenterSaid(let text):
            log.record("presenterSaid", ["text": text])
            addLog("Du: \(text)")
        case .buddySaid(let text):
            log.record("buddySaid", ["text": text])
            addLog("\(activeSession.buddyName): \(text)")
        case .progressChanged:
            progressStamp += 1
            let done = activeSession.moments.filter { director.completed.contains($0.id) }.map(\.title)
            log.record("progress", ["completed": done])
        case .log(let message):
            log.record("log", ["message": message])
            addLog(message)
        }
    }

    private func updateAvatar() {
        let previous = avatar.mode
        if testing {
            avatar.mode = .speaking
        } else {
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
        if avatar.mode != previous {
            EventLog.shared.record("avatar", ["mode": "\(avatar.mode)"])
        }
    }

    // MARK: - Test commands

    /// Commands from the end-to-end tests (inbox or command file).
    func perform(_ command: InboxCommand) {
        EventLog.shared.record("command", ["name": command.name, "value": command.value.map { $0 as Any } ?? NSNull()])
        lastActivityAt = Date()
        let on = command.value.map { $0 == "1" || $0.lowercased() == "true" } ?? true
        switch command.name {
        case "toggle":
            toggleMoment()
        case "interrupt":
            interrupt()
        case "listen":
            Task { @MainActor in
                await self.setListening(on)
            }
        case "reset":
            resetProgress()
        case "queue":
            let moment = activeSession.moments.first { $0.title == command.value }
            queueMoment(moment?.id)
        case "testAvatar":
            testAvatar()
        case "prepare":
            prepareLines()
        case "settings":
            if let tab = command.value.flatMap(SettingsTab.init(rawValue:)) {
                settingsTab = tab
            }
            showSettingsWindow?()
            EventLog.shared.record("settingsShown", ["tab": settingsTab.rawValue])
        case "voicePicker":
            settingsTab = .voice
            showSettingsWindow?()
            voicePickerOpen = true
        case "editShortcuts":
            testEditShortcuts?()
        case "voiceProvider":
            if let provider = command.value.flatMap(VoiceProvider.init(rawValue:)) {
                settings.voiceProvider = provider
            }
        case "elevenVoices":
            listElevenLabsVoicesForTest()
        case "elevenUseVoice":
            useLibraryVoiceForTest(id: command.value ?? "")
        case "snapshot":
            snapshotRobot(name: command.value ?? "snapshot")
        case "quit":
            quit()
        default:
            EventLog.shared.record("error", ["message": "unknown command \(command.name)"])
        }
    }

    /// Renders the robot as it looks now, plus mouth-closed and mouth-open references,
    /// and records how much the mouth changes the picture.
    private func snapshotRobot(name: String) {
        let folder = (options.dataDirectory ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("snapshots", isDirectory: true)
        let hue = settings.robotHue
        var fields: [String: Any] = ["name": name, "mode": "\(avatar.mode)", "mouth": Double(avatar.mouth)]
        if let current = RobotSnapshot.image(mode: avatar.mode == .hidden ? .listening : avatar.mode, mouth: avatar.mouth, hue: hue) {
            let url = folder.appendingPathComponent("\(name)-current.png")
            RobotSnapshot.write(current, to: url)
            fields["current"] = url.path
        }
        if let closed = RobotSnapshot.image(mode: .speaking, mouth: 0, hue: hue),
           let open = RobotSnapshot.image(mode: .speaking, mouth: 0.9, hue: hue) {
            let closedURL = folder.appendingPathComponent("\(name)-mouth-closed.png")
            let openURL = folder.appendingPathComponent("\(name)-mouth-open.png")
            RobotSnapshot.write(closed, to: closedURL)
            RobotSnapshot.write(open, to: openURL)
            fields["closed"] = closedURL.path
            fields["open"] = openURL.path
            fields["mouthDifference"] = RobotSnapshot.difference(closed, open)
        }
        EventLog.shared.record("snapshot", fields)
    }

    func addLog(_ text: String) {
        live.log.append(LogEntry(time: Date(), text: text))
        if live.log.count > 500 {
            live.log.removeFirst(live.log.count - 500)
        }
    }
}
