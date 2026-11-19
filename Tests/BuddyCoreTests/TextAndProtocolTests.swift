import XCTest
@testable import BuddyCore

final class SentenceSplitterTests: XCTestCase {
    func testEmitsSentencesAsTheyComplete() {
        var splitter = SentenceSplitter()
        XCTAssertEqual(splitter.feed("Jag tycker "), [])
        XCTAssertEqual(splitter.feed("att AI är kul. Men "), ["Jag tycker att AI är kul."])
        XCTAssertEqual(splitter.feed("människor är roligare!"), [])
        XCTAssertEqual(splitter.flush(), ["Men människor är roligare!"])
        XCTAssertEqual(splitter.flush(), [])
    }

    func testMergesShortSentences() {
        let parts = SentenceSplitter.split("Ja. Absolut, det tycker jag verkligen. Och du?")
        XCTAssertEqual(parts, ["Ja. Absolut, det tycker jag verkligen.", "Och du?"])
    }

    func testDoesNotSplitDecimalNumbers() {
        let parts = SentenceSplitter.split("Det kostar 3.5 miljoner kronor per år, ungefär.")
        XCTAssertEqual(parts, ["Det kostar 3.5 miljoner kronor per år, ungefär."])
    }

    func testSanitizeRemovesThingsThatShouldNotBeSpoken() {
        XCTAssertEqual(SpeechText.sanitize("*ler* Hej **du**! 🤖"), "Hej du!")
        XCTAssertEqual(SpeechText.sanitize("Hej (skrattar) på dig"), "Hej på dig")
        XCTAssertEqual(SpeechText.sanitize("- Punkt ett"), "Punkt ett")
        XCTAssertEqual(SpeechText.sanitize("Klockan är 10 och 25"), "Klockan är 10 och 25")
    }
}

final class ClaudeAPITests: XCTestCase {
    func testParsesTextDelta() {
        let line = #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hej"}}"#
        XCTAssertEqual(ClaudeAPI.parse(sseLine: line), .text("Hej"))
    }

    func testIgnoresThinkingDeltasAndEventLines() {
        let thinking = #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":""}}"#
        XCTAssertEqual(ClaudeAPI.parse(sseLine: thinking), .ignored)
        XCTAssertEqual(ClaudeAPI.parse(sseLine: "event: content_block_delta"), .ignored)
        XCTAssertEqual(ClaudeAPI.parse(sseLine: ""), .ignored)
    }

    func testParsesStopReasonStopAndError() {
        let delta = #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":12}}"#
        XCTAssertEqual(ClaudeAPI.parse(sseLine: delta), .stopReason("end_turn"))
        XCTAssertEqual(ClaudeAPI.parse(sseLine: #"data: {"type":"message_stop"}"#), .messageStop)
        let error = #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
        XCTAssertEqual(ClaudeAPI.parse(sseLine: error), .error("Overloaded"))
    }

    func testRequestBody() throws {
        let request = ReplyRequest(system: "Sys", messages: [ChatMessage(role: .user, text: "Hej")])
        let opus = try JSONSerialization.jsonObject(with: ClaudeAPI.body(model: "claude-opus-5-5", request: request)) as? [String: Any]
        XCTAssertEqual(opus?["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(opus?["stream"] as? Bool, true)
        XCTAssertEqual(opus?["system"] as? String, "Sys")
        XCTAssertEqual(opus?["fallbacks"] as? String, "default")
        XCTAssertEqual((opus?["output_config"] as? [String: Any])?["effort"] as? String, "low")
        XCTAssertNil(opus?["temperature"])
        let messages = opus?["messages"] as? [[String: Any]]
        XCTAssertEqual(messages?.first?["role"] as? String, "user")
        XCTAssertEqual(messages?.first?["content"] as? String, "Hej")

        let haiku = try JSONSerialization.jsonObject(with: ClaudeAPI.body(model: "claude-haiku-5-5", request: request)) as? [String: Any]
        XCTAssertNil(haiku?["fallbacks"])
    }

    func testHeaders() {
        let opus = ClaudeAPI.headers(apiKey: "k", model: "claude-opus-5-5")
        XCTAssertEqual(opus["x-api-key"], "k")
        XCTAssertEqual(opus["anthropic-version"], "2026-10-21")
        XCTAssertEqual(opus["anthropic-beta"], "server-side-fallback-2026-07-01")
        XCTAssertNil(ClaudeAPI.headers(apiKey: "k", model: "claude-haiku-5-5")["anthropic-beta"])
    }

    func testConversationKeepsRolesAlternating() {
        var c = Conversation()
        c.appendAssistant("ignoreras")
        c.appendUser("ett")
        c.appendUser("två")
        c.appendAssistant("svar")
        c.appendAssistant("")
        XCTAssertEqual(c.messages, [
            ChatMessage(role: .user, text: "ett\n\ntvå"),
            ChatMessage(role: .assistant, text: "svar"),
        ])
    }
}

final class ModelAndPromptTests: XCTestCase {
    func testDecodesMinimalJSONWithDefaults() throws {
        let json = """
        {"name": "Mitt föredrag", "triggers": ["vad tycker du buddy"],
         "moments": [{"title": "Intro", "script": "Säg hej"}]}
        """
        let session = try JSONDecoder().decode(Session.self, from: Data(json.utf8))
        XCTAssertEqual(session.name, "Mitt föredrag")
        XCTAssertEqual(session.buddyName, "Buddy")
        XCTAssertEqual(session.moments.count, 1)
        XCTAssertEqual(session.moments[0].mode, .ai)
        XCTAssertEqual(session.moments[0].maxTurns, 3)
        XCTAssertTrue(session.moments[0].enabled)
        XCTAssertFalse(session.fallbackLines.isEmpty)
    }

    func testExampleFileDecodes() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("examples/ai-foredrag.json")
        let session = try JSONDecoder().decode(Session.self, from: Data(contentsOf: url))
        XCTAssertEqual(session.moments.count, 3)
        XCTAssertEqual(session.moments[2].mode, .scripted)
        XCTAssertEqual(session.moments[2].lines.count, 2)
    }

    func testRoundTrip() throws {
        let original = Session.example()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Session.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testScriptLinesForSpeaker() {
        let script = """
        Pål: Vad tycker du, Buddy?
        Buddy: Jag tycker att du pratar för fort.
        Pål: Okej.
        buddy :  Skämt åsido, bra jobbat!
        """
        XCTAssertEqual(ScriptTools.lines(spokenBy: "Buddy", in: script), [
            "Jag tycker att du pratar för fort.",
            "Skämt åsido, bra jobbat!",
        ])
    }

    func testSystemPromptContainsPersonaScriptAndRules() {
        var session = Session(name: "T", buddyName: "Robban", context: "Föredrag om AI.")
        session.maxWordsPerReply = 30
        let moment = Moment(title: "Intro", script: "Robban hälsar.", lines: ["Hej hej!"])
        let prompt = PromptBuilder.system(session: session, moment: moment)
        XCTAssertTrue(prompt.contains("Föredrag om AI."))
        XCTAssertTrue(prompt.contains("Du heter Robban"))
        XCTAssertTrue(prompt.contains("Robban hälsar."))
        XCTAssertTrue(prompt.contains("- Hej hej!"))
        XCTAssertTrue(prompt.contains("30 ord"))
    }

    func testTurnNotes() {
        XCTAssertTrue(PromptBuilder.turnNote(turn: 1, maxTurns: 3).contains("1 av högst 3"))
        XCTAssertTrue(PromptBuilder.turnNote(turn: 3, maxTurns: 3).contains("sista svar"))
        XCTAssertTrue(PromptBuilder.turnNote(turn: 5, maxTurns: 0).contains("avslutar"))
    }
}
