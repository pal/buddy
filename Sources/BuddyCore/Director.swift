import Foundation

/// Where Buddy is in the listen → trigger → talk → listen cycle.
public enum DirectorPhase: String, Equatable, Sendable {
    /// Not listening for triggers (the user paused Buddy).
    case paused
    /// Waiting for a trigger phrase.
    case listening
    /// Heard a trigger; waiting for the speaker to finish the sentence.
    case triggered
    /// Waiting for the first words from Claude.
    case thinking
    /// Buddy is talking.
    case speaking
    /// Buddy has answered and waits for the speaker's reply or an end phrase.
    case awaitingReply
    /// Saying goodbye before going back to listening.
    case closing

    /// True while a moment is running (the avatar is on screen).
    public var isActive: Bool { self != .paused && self != .listening }
}

public enum EndReason: String, Sendable {
    case endPhrase, lastTurn, timeout, manual, sessionChanged
}

public enum PhraseKind: String, Sendable {
    case trigger, endPhrase
}

public enum DirectorEvent: Sendable {
    case phase(DirectorPhase)
    case momentStarted(Moment)
    case momentEnded(Moment, EndReason)
    /// A trigger or end phrase was recognized.
    case heard(phrase: String, kind: PhraseKind)
    /// Whether the microphone should be listening. Off while Buddy talks, so it doesn't hear itself.
    case microphone(Bool)
    case presenterSaid(String)
    case buddySaid(String)
    case progressChanged
    case log(String)
}

public struct DirectorSettings: Equatable, Sendable {
    /// Per-word similarity needed for a phrase to match (lower = more forgiving).
    public var matchThreshold: Double = 0.75
    /// Silence after a trigger before Buddy answers (lets the speaker finish the question).
    public var triggerSilence: TimeInterval = 0.9
    /// Silence that marks the end of the speaker's reply during a dialog.
    public var replySilence: TimeInterval = 1.4
    /// Answer anyway if the speaker keeps talking this long after a trigger.
    public var maxTriggerWait: TimeInterval = 8
    /// End the moment quietly if nobody says anything for this long (0 = never).
    public var idleTimeout: TimeInterval = 30
    /// Use a fallback line if Claude hasn't produced any text by then.
    public var thinkingTimeout: TimeInterval = 12
    /// Hard cap on how much of a Claude reply is spoken.
    public var maxSpokenCharacters: Int = 700
    /// The microphone must also have been quiet this long before an utterance counts as
    /// finished; speech recognition can lag a second or more behind the voice.
    public var voiceSilence: TimeInterval = 0.6
    /// Longest extra wait for the microphone to go quiet (protects against a noisy room).
    public var maxVoiceWait: TimeInterval = 2.0
    /// Extra wait when the speaker stops in the middle of an end phrase ("tack …").
    public var endPhraseGrace: TimeInterval = 1.5

    public init() {}
}

/// Speech output as seen by the director. `isBusy` must be true from `enqueue` until playback ends.
@MainActor
public protocol VoiceOutput: AnyObject {
    func enqueue(_ sentence: String)
    func stopSpeaking()
    var isBusy: Bool { get }
}

/// The dialog state machine. Feed it transcripts with `hear`, call `tick` about ten times a
/// second, and it decides when Buddy starts, what it says, and when it stops.
@MainActor
public final class Director {
    public private(set) var session: Session
    public var settings: DirectorSettings {
        didSet { matcher = PhraseMatcher.forSession(session, threshold: settings.matchThreshold) }
    }
    public private(set) var phase: DirectorPhase = .paused
    public private(set) var activeMoment: Moment?
    public private(set) var turn = 0
    public private(set) var completed: Set<UUID> = []
    /// Moment that the next general trigger starts, chosen by the user.
    public private(set) var queuedMomentID: UUID?
    public var onEvent: ((DirectorEvent) -> Void)?

    private let brain: ReplyGenerator
    private let voice: VoiceOutput
    private let now: () -> Date
    private var matcher: PhraseMatcher

    // Transcript state. A "segment" is one recognition task; its text grows as words arrive.
    private var externalID = -1
    private var minExternalID = 0
    private var segment = TokenizedText.empty
    /// Tokens before this index have been used (as trigger, end phrase or reply).
    private var consumed = 0
    /// Where the speaker's current utterance starts in the segment.
    private var utteranceStart = 0
    /// Utterance text carried over from earlier segments.
    private var carry = ""
    private var history: [String] = []
    private var lastHeardChange: Date
    /// Last time the microphone level indicated speech.
    private var lastVoiceAt: Date = .distantPast
    private var noiseFloor: Float = 0.002

    // Dialog state.
    private var background = ""
    private var conversation = Conversation()
    private var phaseSince: Date
    private var triggerAt: Date
    private var restingPhase: DirectorPhase = .listening
    private var endingReason: EndReason = .manual
    private var replyTask: Task<Void, Never>?
    private var replyGeneration = 0
    private var splitter = SentenceSplitter()
    private var spokenText = ""
    private var receivedText = false
    private var streamDone = false
    private var finishAfterReply = false
    private var micWanted = false

    public init(
        session: Session,
        settings: DirectorSettings = DirectorSettings(),
        brain: ReplyGenerator,
        voice: VoiceOutput,
        now: @escaping () -> Date = { Date() }
    ) {
        self.session = session
        self.settings = settings
        self.brain = brain
        self.voice = voice
        self.now = now
        self.matcher = PhraseMatcher.forSession(session, threshold: settings.matchThreshold)
        let t = now()
        lastHeardChange = t
        phaseSince = t
        triggerAt = t
    }

    // MARK: - Control

    /// Start listening for triggers.
    public func start() {
        guard phase == .paused else { return }
        consumed = segment.tokens.count
        setPhase(.listening)
        log("Lyssnar efter triggerfraser")
    }

    /// Stop listening. Ends a running moment.
    public func pause() {
        if phase.isActive {
            restingPhase = .paused
            end(.manual, farewell: false)
        }
        setPhase(.paused)
    }

    /// Hotkey: start the next moment now, or end the running one.
    public func toggle() {
        if phase.isActive {
            log("Avslutar manuellt")
            end(.manual, farewell: false)
            return
        }
        let moment = nextMoment()
        background = context(before: segment.tokens.count)
        begin(moment, via: nil)
        reply(to: "", manual: true)
    }

    /// Hotkey: stop the current reply but stay in the dialog.
    public func interrupt() {
        switch phase {
        case .thinking, .speaking:
            cancelReply()
            voice.stopSpeaking()
            streamDone = true
            replyFinished()
        case .closing:
            voice.stopSpeaking()
            finishMoment()
        default:
            break
        }
    }

    /// Use a new or edited session. Progress is kept if it is the same presentation.
    public func updateSession(_ newSession: Session) {
        let samePresentation = newSession.id == session.id
        session = newSession
        matcher = PhraseMatcher.forSession(newSession, threshold: settings.matchThreshold)
        if !samePresentation {
            if phase.isActive { end(.sessionChanged, farewell: false) }
            completed = []
            queuedMomentID = nil
            emit(.progressChanged)
            return
        }
        if let active = activeMoment, active.id != Session.improvisationID {
            if let updated = newSession.moments.first(where: { $0.id == active.id }) {
                activeMoment = updated
            } else {
                end(.sessionChanged, farewell: false)
            }
        }
        completed = completed.filter { id in newSession.moments.contains { $0.id == id } }
        if let q = queuedMomentID, !newSession.moments.contains(where: { $0.id == q }) {
            queuedMomentID = nil
        }
        emit(.progressChanged)
    }

    public func resetProgress() {
        completed = []
        queuedMomentID = nil
        emit(.progressChanged)
        log("Alla moment är återställda")
    }

    /// Choose which moment the next general trigger starts (nil = the first one not done).
    public func queue(_ momentID: UUID?) {
        queuedMomentID = momentID
        emit(.progressChanged)
    }

    /// The moment a general trigger would start right now.
    public func nextMoment() -> Moment {
        let enabled = session.moments.filter(\.enabled)
        if let q = queuedMomentID, let m = enabled.first(where: { $0.id == q }) {
            return m
        }
        return enabled.first { !completed.contains($0.id) } ?? session.improvisationMoment()
    }

    // MARK: - Input

    /// A transcript update. `segment` identifies the recognition task; `text` is everything
    /// recognized in that task so far.
    public func hear(segment id: Int, text: String) {
        guard id >= minExternalID, id >= externalID else { return }
        if id != externalID {
            externalID = id
            rollSegment()
        }
        let tokenized = TokenizedText(text)
        if tokenized.tokens != segment.tokens {
            lastHeardChange = now()
        }
        segment = tokenized
        consumed = min(consumed, segment.tokens.count)
        utteranceStart = min(utteranceStart, segment.tokens.count)
        process()
    }

    /// Typed text treated as a finished spoken sentence (for rehearsing without a microphone).
    /// The caller should restart speech recognition so later audio starts a new segment.
    public func simulate(_ text: String) {
        minExternalID = externalID + 1
        rollSegment()
        segment = TokenizedText(text)
        log("Simulerat tal: \(text)")
        process()
        lastHeardChange = .distantPast
        triggerAt = .distantPast
    }

    /// Drive timing. Call roughly every 100 ms.
    public func tick() {
        let t = now()
        switch phase {
        case .triggered:
            if utteranceFinished(at: t, silence: settings.triggerSilence)
                || t.timeIntervalSince(triggerAt) >= settings.maxTriggerWait {
                let said = currentUtterance()
                takeUtterance()
                if !said.isEmpty { emit(.presenterSaid(said)) }
                reply(to: said, manual: false)
            }
        case .thinking:
            if !receivedText, t.timeIntervalSince(phaseSince) >= settings.thinkingTimeout {
                log("Inget svar från Claude i tid – använder reservreplik")
                cancelReply()
                useFallback()
            }
        case .speaking:
            if streamDone, !voice.isBusy {
                replyFinished()
            }
        case .awaitingReply:
            let said = currentUtterance()
            if !said.isEmpty {
                if utteranceFinished(at: t, silence: settings.replySilence) {
                    takeUtterance()
                    emit(.presenterSaid(said))
                    reply(to: said, manual: false)
                }
            } else if settings.idleTimeout > 0,
                      t.timeIntervalSince(max(phaseSince, lastHeardChange)) >= settings.idleTimeout {
                log("Ingen fortsättning – Buddy drar sig tillbaka")
                end(.timeout, farewell: false)
            }
        case .closing:
            if !voice.isBusy { finishMoment() }
        case .listening, .paused:
            break
        }
    }

    /// Microphone level (RMS, 0...1), called about ten times a second. It tells a real pause
    /// from speech recognition that has not caught up yet.
    public func audioLevel(_ level: Float) {
        if level < noiseFloor {
            noiseFloor = level
        } else {
            noiseFloor += (level - noiseFloor) * 0.002
        }
        if level > max(0.004, noiseFloor * 3) {
            lastVoiceAt = now()
        }
    }

    /// The speaker has finished: the transcript has stopped changing, the microphone is quiet
    /// (or has not gone quiet within a reasonable time), and they did not stop halfway through
    /// an end phrase.
    private func utteranceFinished(at t: Date, silence: TimeInterval) -> Bool {
        let quietText = t.timeIntervalSince(lastHeardChange)
        var needed = silence
        if endsWithStartOfEndPhrase() {
            needed += settings.endPhraseGrace
        }
        guard quietText >= needed else { return false }
        let quietVoice = t.timeIntervalSince(lastVoiceAt)
        return quietVoice >= settings.voiceSilence || quietText >= needed + settings.maxVoiceWait
    }

    /// True when the last words heard are the beginning of an end phrase, like "tack" in "tack buddy".
    private func endsWithStartOfEndPhrase() -> Bool {
        guard let moment = activeMoment else { return false }
        let heard = segment.tokens[min(max(consumed, utteranceStart), segment.tokens.count)...].map(matcher.canonical)
        guard !heard.isEmpty else { return false }
        for phrase in moment.endPhrases + session.endPhrases {
            let words = TextNormalizer.tokens(phrase).map(matcher.canonical)
            guard words.count > 1 else { continue }
            for length in stride(from: min(words.count - 1, heard.count), through: 1, by: -1) {
                let tail = Array(heard.suffix(length))
                let head = Array(words.prefix(length))
                if zip(tail, head).allSatisfy({ PhraseMatcher.similarity($0, $1) >= matcher.requiredScore(for: $1) }) {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Transcript handling

    private func rollSegment() {
        if phase == .triggered || phase == .awaitingReply {
            carry = join(carry, segment.rawText(tokens: utteranceStart..<segment.tokens.count))
        }
        remember(segment.raw)
        segment = .empty
        consumed = 0
        utteranceStart = 0
    }

    private func process() {
        switch phase {
        case .listening:
            detectTrigger()
        case .triggered, .thinking, .awaitingReply:
            detectEndPhrase()
        default:
            break
        }
    }

    private func detectTrigger() {
        guard let match = matcher.firstMatch(of: allTriggers(), in: segment.tokens, from: consumed) else { return }
        // The question may start a little before the trigger, but never in words already used.
        utteranceStart = max(consumed, match.range.lowerBound - 30)
        consumed = match.range.upperBound
        carry = ""
        background = context(before: utteranceStart)
        emit(.heard(phrase: match.phrase, kind: .trigger))
        begin(momentFor(trigger: match.phrase), via: match.phrase)
    }

    private func detectEndPhrase() {
        guard let moment = activeMoment else { return }
        let phrases = moment.endPhrases + session.endPhrases
        let from = max(consumed, utteranceStart)
        guard let match = matcher.firstMatch(of: phrases, in: segment.tokens, from: from) else { return }
        consumed = match.range.upperBound
        utteranceStart = consumed
        carry = ""
        emit(.heard(phrase: match.phrase, kind: .endPhrase))
        log("Hörde «\(match.phrase)» – avslutar \(moment.title)")
        end(.endPhrase, farewell: true)
    }

    private func allTriggers() -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for phrase in session.triggers + session.moments.filter(\.enabled).flatMap(\.triggers) {
            let key = TextNormalizer.key(phrase)
            if !key.isEmpty, seen.insert(key).inserted { out.append(phrase) }
        }
        return out
    }

    /// A moment's own trigger picks that moment; a general trigger picks the next one.
    func momentFor(trigger phrase: String) -> Moment {
        let key = TextNormalizer.key(phrase)
        let specific = session.moments.filter { m in
            m.enabled && m.triggers.contains { TextNormalizer.key($0) == key }
        }
        if let last = specific.last {
            return specific.first { !completed.contains($0.id) } ?? last
        }
        return nextMoment()
    }

    private func currentUtterance() -> String {
        join(carry, segment.rawText(tokens: utteranceStart..<segment.tokens.count))
    }

    private func takeUtterance() {
        consumed = segment.tokens.count
        utteranceStart = consumed
        carry = ""
    }

    private func context(before tokenIndex: Int) -> String {
        let current = segment.rawText(tokens: 0..<tokenIndex)
        var text = (history + [current]).filter { !$0.isEmpty }.joined(separator: " ")
        if text.count > 1500 {
            text = "…" + String(text.suffix(1500))
        }
        return text
    }

    private func remember(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        history.append(trimmed)
        while history.count > 1, history.reduce(0, { $0 + $1.count }) > 3000 {
            history.removeFirst()
        }
    }

    private func join(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }

    // MARK: - Dialog

    private func begin(_ moment: Moment, via phrase: String?) {
        restingPhase = phase == .paused ? .paused : .listening
        activeMoment = moment
        turn = 0
        conversation = Conversation()
        lastHeardChange = now()
        triggerAt = now()
        if let phrase {
            log("Hörde «\(phrase)» → \(moment.title)")
        } else {
            log("Startar \(moment.title)")
        }
        emit(.momentStarted(moment))
        setPhase(.triggered)
    }

    private func maxTurns(for moment: Moment) -> Int {
        guard moment.mode == .scripted else { return moment.maxTurns }
        return moment.maxTurns > 0 ? min(moment.maxTurns, moment.lines.count) : moment.lines.count
    }

    private func reply(to said: String, manual: Bool) {
        guard let moment = activeMoment else { return }
        turn += 1
        let limit = maxTurns(for: moment)
        finishAfterReply = limit > 0 && turn >= limit

        if moment.mode == .scripted {
            let index = turn - 1
            guard index < moment.lines.count else {
                end(.lastTurn, farewell: false)
                return
            }
            if index == moment.lines.count - 1 { finishAfterReply = true }
            speakFixed(moment.lines[index])
            return
        }

        let userText = turn == 1
            ? PromptBuilder.opening(background: background, utterance: said, manual: manual, turn: turn, maxTurns: limit)
            : PromptBuilder.followUp(utterance: said, turn: turn, maxTurns: limit)
        conversation.appendUser(userText)
        let request = ReplyRequest(
            system: PromptBuilder.system(session: session, moment: moment),
            messages: conversation.messages
        )

        cancelReply()
        splitter = SentenceSplitter()
        spokenText = ""
        receivedText = false
        streamDone = false
        let generation = replyGeneration
        setPhase(.thinking)
        let stream = brain.streamReply(request)
        replyTask = Task { @MainActor [weak self] in
            do {
                for try await chunk in stream {
                    if Task.isCancelled { return }
                    self?.receive(chunk, generation: generation)
                }
                self?.streamEnded(generation: generation, error: nil)
            } catch {
                self?.streamEnded(generation: generation, error: error)
            }
        }
    }

    private func receive(_ chunk: String, generation: Int) {
        guard generation == replyGeneration, phase == .thinking || phase == .speaking else { return }
        receivedText = true
        for sentence in splitter.feed(chunk) {
            speak(sentence, capped: true)
        }
    }

    private func streamEnded(generation: Int, error: Error?) {
        guard generation == replyGeneration, phase == .thinking || phase == .speaking else { return }
        replyTask = nil
        if let error {
            log("Fel från Claude: \(error.localizedDescription)")
            if spokenText.isEmpty {
                useFallback()
                return
            }
        }
        for sentence in splitter.flush() {
            speak(sentence, capped: true)
        }
        streamDone = true
        if spokenText.isEmpty {
            log("Claude gav inget svar – använder reservreplik")
            useFallback()
        }
    }

    private func speak(_ sentence: String, capped: Bool) {
        if capped, spokenText.count >= settings.maxSpokenCharacters { return }
        spokenText = join(spokenText, sentence)
        if phase != .speaking { setPhase(.speaking) }
        voice.enqueue(sentence)
    }

    private func speakFixed(_ text: String) {
        cancelReply()
        splitter = SentenceSplitter()
        spokenText = ""
        receivedText = true
        for sentence in SentenceSplitter.split(text) {
            speak(sentence, capped: false)
        }
        streamDone = true
        if spokenText.isEmpty { replyFinished() }
    }

    private func useFallback() {
        guard let moment = activeMoment else { return }
        let index = turn - 1
        let line = index >= 0 && index < moment.lines.count ? moment.lines[index] : session.fallbackLines.randomElement()
        if let line {
            speakFixed(line)
        } else {
            streamDone = true
            replyFinished()
        }
    }

    private func replyFinished() {
        conversation.appendAssistant(spokenText)
        if !spokenText.isEmpty { emit(.buddySaid(spokenText)) }
        spokenText = ""
        if finishAfterReply {
            end(.lastTurn, farewell: false)
            return
        }
        takeUtterance()
        lastHeardChange = now()
        setPhase(.awaitingReply)
    }

    private func cancelReply() {
        replyGeneration += 1
        replyTask?.cancel()
        replyTask = nil
    }

    private func end(_ reason: EndReason, farewell: Bool) {
        guard let moment = activeMoment else {
            setPhase(restingPhase)
            return
        }
        cancelReply()
        voice.stopSpeaking()
        endingReason = reason
        if moment.id != Session.improvisationID {
            completed.insert(moment.id)
        }
        if queuedMomentID == moment.id { queuedMomentID = nil }
        emit(.progressChanged)

        let lines = moment.farewells.isEmpty ? session.farewells : moment.farewells
        if farewell, let line = lines.randomElement() {
            setPhase(.closing)
            for sentence in SentenceSplitter.split(line) { voice.enqueue(sentence) }
            emit(.buddySaid(line))
        } else {
            finishMoment()
        }
    }

    private func finishMoment() {
        let moment = activeMoment
        activeMoment = nil
        conversation = Conversation()
        turn = 0
        takeUtterance()
        setPhase(restingPhase)
        if let moment { emit(.momentEnded(moment, endingReason)) }
    }

    // MARK: - Helpers

    private func setPhase(_ newPhase: DirectorPhase) {
        guard newPhase != phase else { return }
        phase = newPhase
        phaseSince = now()
        emit(.phase(newPhase))
        let wantsMic = !(newPhase == .paused || newPhase == .speaking || newPhase == .closing)
        if wantsMic != micWanted {
            micWanted = wantsMic
            if !wantsMic {
                // Late results from the stopped recognition task may contain Buddy's own voice.
                minExternalID = externalID + 1
            }
            emit(.microphone(wantsMic))
        }
    }

    private func emit(_ event: DirectorEvent) {
        onEvent?(event)
    }

    private func log(_ message: String) {
        emit(.log(message))
    }
}
