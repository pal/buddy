import XCTest
@testable import BuddyCore

@MainActor
final class FakeVoice: VoiceOutput {
    var spoken: [String] = []
    var isBusy = false

    func enqueue(_ sentence: String) {
        spoken.append(sentence)
        isBusy = true
    }

    func stopSpeaking() {
        isBusy = false
    }

    /// Pretend playback finished.
    func finish() {
        isBusy = false
    }
}

struct FakeError: Error {}

final class FakeBrain: ReplyGenerator {
    var replies: [[String]] = []
    var requests: [ReplyRequest] = []
    var failing = false

    func streamReply(_ request: ReplyRequest) -> AsyncThrowingStream<String, Error> {
        requests.append(request)
        let chunks = replies.isEmpty ? ["Hej från Claude."] : replies.removeFirst()
        let failing = self.failing
        return AsyncThrowingStream { continuation in
            if failing {
                continuation.finish(throwing: FakeError())
                return
            }
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }
}

final class TestClock {
    var now = Date(timeIntervalSince1970: 1_000_000)
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

/// Wires a Director to fakes and a controllable clock.
@MainActor
final class Harness {
    let clock: TestClock
    let voice: FakeVoice
    let brain: FakeBrain
    let director: Director
    let first: Moment
    let second: Moment
    let third: Moment
    var events: [DirectorEvent] = []
    var segment = 0

    init() {
        let clock = TestClock()
        let voice = FakeVoice()
        let brain = FakeBrain()
        let first = Moment(title: "Ett", maxTurns: 3)
        let second = Moment(title: "Två", triggers: ["berätta om robotar buddy"], maxTurns: 1)
        let third = Moment(title: "Tre", mode: .scripted, lines: ["Första repliken här.", "Andra repliken här."], maxTurns: 0)
        let session = Session(
            name: "Test",
            triggers: ["vad tycker du buddy"],
            endPhrases: ["tack buddy"],
            farewells: ["Hej då!"],
            fallbackLines: ["Reservrepliken."],
            moments: [first, second, third]
        )
        self.clock = clock
        self.voice = voice
        self.brain = brain
        self.first = first
        self.second = second
        self.third = third
        self.director = Director(session: session, brain: brain, voice: voice, now: { clock.now })
        director.onEvent = { [weak self] event in self?.events.append(event) }
        director.start()
    }

    /// Lets the reply task run on the main actor.
    func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    /// Simulates the recognizer starting a new task and hearing `text`.
    func say(_ text: String) {
        segment += 1
        director.hear(segment: segment, text: text)
    }

    func wait(_ seconds: TimeInterval) {
        clock.advance(seconds)
        director.tick()
    }

    func finishSpeaking() {
        voice.finish()
        director.tick()
    }
}

@MainActor
final class DirectorTests: XCTestCase {
    func testTriggerStartsDialogAndEndPhraseEndsIt() async {
        let h = Harness()
        h.brain.replies = [["Jag tycker ", "att AI är kul. Men ", "människor är roligare!"]]
        h.say("Det här är spännande. Vad tycker du, Buddy?")
        XCTAssertEqual(h.director.phase, .triggered)
        XCTAssertEqual(h.director.activeMoment?.title, "Ett")

        h.wait(0.3)
        XCTAssertEqual(h.director.phase, .triggered, "waits for the speaker to finish")
        h.wait(1.0)
        XCTAssertEqual(h.director.phase, .thinking)
        await h.settle()
        XCTAssertEqual(h.director.phase, .speaking)
        XCTAssertEqual(h.voice.spoken, ["Jag tycker att AI är kul.", "Men människor är roligare!"])

        let opening = h.brain.requests.first?.messages.last?.text ?? ""
        XCTAssertTrue(opening.contains("Vad tycker du, Buddy?"))
        XCTAssertTrue(h.brain.requests.first?.system.contains("Det här momentet: Ett") ?? false)

        h.director.tick()
        XCTAssertEqual(h.director.phase, .speaking, "still talking")
        h.finishSpeaking()
        XCTAssertEqual(h.director.phase, .awaitingReply)

        h.say("Tack Buddy!")
        XCTAssertEqual(h.director.phase, .closing)
        XCTAssertEqual(h.voice.spoken.last, "Hej då!")
        h.finishSpeaking()
        XCTAssertEqual(h.director.phase, .listening)
        XCTAssertNil(h.director.activeMoment)
        XCTAssertTrue(h.director.completed.contains(h.first.id))
    }

    func testFollowUpTurnSendsHistory() async {
        let h = Harness()
        h.brain.replies = [["Första svaret."], ["Andra svaret."]]
        h.say("vad tycker du buddy")
        h.wait(1.0)
        await h.settle()
        h.finishSpeaking()
        XCTAssertEqual(h.director.phase, .awaitingReply)

        h.say("Men är det inte farligt?")
        h.wait(0.5)
        XCTAssertEqual(h.director.phase, .awaitingReply, "waits for a pause")
        h.wait(1.5)
        XCTAssertEqual(h.director.phase, .thinking)
        await h.settle()
        let messages = h.brain.requests.last?.messages ?? []
        XCTAssertEqual(messages.map(\.role), [.user, .assistant, .user])
        XCTAssertEqual(messages[1].text, "Första svaret.")
        XCTAssertTrue(messages[2].text.contains("Men är det inte farligt?"))
    }

    func testMomentSpecificTriggerPicksThatMoment() {
        let h = Harness()
        h.say("Kan du berätta om robotar, Buddy?")
        XCTAssertEqual(h.director.activeMoment?.title, "Två")
    }

    func testGeneralTriggerPicksNextUnfinishedMoment() async {
        let h = Harness()
        h.say("vad tycker du buddy")
        XCTAssertEqual(h.director.activeMoment?.title, "Ett")
        h.director.toggle()
        XCTAssertEqual(h.director.phase, .listening)

        h.say("vad tycker du buddy")
        XCTAssertEqual(h.director.activeMoment?.title, "Två")
    }

    func testQueuedMomentWins() {
        let h = Harness()
        h.director.queue(h.third.id)
        h.say("vad tycker du buddy")
        XCTAssertEqual(h.director.activeMoment?.title, "Tre")
    }

    func testMaxTurnsEndsMomentAfterLastReply() async {
        let h = Harness()
        h.say("berätta om robotar buddy")
        h.wait(1.0)
        await h.settle()
        XCTAssertEqual(h.director.phase, .speaking)
        h.finishSpeaking()
        XCTAssertEqual(h.director.phase, .listening)
        XCTAssertTrue(h.director.completed.contains(h.second.id))
        XCTAssertTrue(h.brain.requests[0].messages[0].text.contains("sista svar"))
    }

    func testScriptedMomentSpeaksLinesWithoutClaude() async {
        let h = Harness()
        h.director.queue(h.third.id)
        h.say("vad tycker du buddy")
        h.wait(1.0)
        XCTAssertEqual(h.director.phase, .speaking)
        XCTAssertEqual(h.voice.spoken, ["Första repliken här."])
        h.finishSpeaking()
        XCTAssertEqual(h.director.phase, .awaitingReply)

        h.say("Och sen då?")
        h.wait(2.0)
        XCTAssertEqual(h.voice.spoken.last, "Andra repliken här.")
        h.finishSpeaking()
        XCTAssertEqual(h.director.phase, .listening)
        XCTAssertTrue(h.brain.requests.isEmpty)
    }

    func testClaudeErrorUsesFallbackLine() async {
        let h = Harness()
        h.brain.failing = true
        h.say("vad tycker du buddy")
        h.wait(1.0)
        await h.settle()
        XCTAssertEqual(h.director.phase, .speaking)
        XCTAssertEqual(h.voice.spoken, ["Reservrepliken."])
    }

    func testLateResultsFromStoppedRecognitionAreIgnored() async {
        let h = Harness()
        h.say("vad tycker du buddy")
        h.wait(1.0)
        await h.settle()
        XCTAssertEqual(h.director.phase, .speaking)
        // The old recognition task reports Buddy's own voice after the mic was turned off.
        h.director.hear(segment: h.segment, text: "vad tycker du buddy hej från claude tack buddy")
        h.finishSpeaking()
        XCTAssertEqual(h.director.phase, .awaitingReply)
        h.wait(5)
        XCTAssertEqual(h.director.phase, .awaitingReply, "nothing was taken as the speaker's reply")
    }

    func testIdleTimeoutEndsMoment() async {
        let h = Harness()
        h.say("vad tycker du buddy")
        h.wait(1.0)
        await h.settle()
        h.finishSpeaking()
        XCTAssertEqual(h.director.phase, .awaitingReply)
        h.wait(31)
        XCTAssertEqual(h.director.phase, .listening)
    }

    func testToggleStartsAndStopsManually() async {
        let h = Harness()
        h.director.toggle()
        XCTAssertEqual(h.director.phase, .thinking)
        XCTAssertEqual(h.director.activeMoment?.title, "Ett")
        await h.settle()
        h.director.toggle()
        XCTAssertEqual(h.director.phase, .listening)
        XCTAssertNil(h.director.activeMoment)
    }

    func testSimulatedSpeechTriggersImmediately() async {
        let h = Harness()
        h.director.simulate("Vad tycker du Buddy?")
        XCTAssertEqual(h.director.phase, .triggered)
        h.director.tick()
        XCTAssertEqual(h.director.phase, .thinking)
    }

    func testMicrophoneIsOffWhileSpeaking() async {
        let h = Harness()
        h.say("vad tycker du buddy")
        h.wait(1.0)
        await h.settle()
        let micEvents = h.events.compactMap { event -> Bool? in
            if case .microphone(let on) = event { return on }
            return nil
        }
        XCTAssertEqual(micEvents, [true, false])
    }

    func testPausedDirectorIgnoresTriggers() {
        let h = Harness()
        h.director.pause()
        h.say("vad tycker du buddy")
        XCTAssertEqual(h.director.phase, .paused)
        XCTAssertNil(h.director.activeMoment)
    }
}
