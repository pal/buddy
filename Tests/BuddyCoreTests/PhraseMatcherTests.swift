import XCTest
@testable import BuddyCore

final class PhraseMatcherTests: XCTestCase {
    private let session = Session(name: "Test")

    private func matcher() -> PhraseMatcher {
        PhraseMatcher.forSession(session, threshold: 0.75)
    }

    func testExactPhraseMatches() {
        let tokens = TextNormalizer.tokens("Det här är spännande. Vad tycker du, Buddy?")
        let match = matcher().firstMatch(of: ["vad tycker du buddy"], in: tokens)
        XCTAssertEqual(match?.phrase, "vad tycker du buddy")
        XCTAssertEqual(match?.range, 4..<8)
    }

    func testColloquialFormsAndNameVariants() {
        let tokens = TextNormalizer.tokens("va tycker du baddy")
        XCTAssertNotNil(matcher().firstMatch(of: ["vad tycker du buddy"], in: tokens))

        let body = TextNormalizer.tokens("vad tycker du body")
        XCTAssertNotNil(matcher().firstMatch(of: ["vad tycker du buddy"], in: body))
    }

    func testAllowsOneFillerWordBetweenWords() {
        let tokens = TextNormalizer.tokens("vad tycker eh du buddy")
        XCTAssertNotNil(matcher().firstMatch(of: ["vad tycker du buddy"], in: tokens))

        let twoFillers = TextNormalizer.tokens("vad tycker eh öh du buddy")
        XCTAssertNil(matcher().firstMatch(of: ["vad tycker du buddy"], in: twoFillers))
    }

    func testIncompletePhraseDoesNotMatch() {
        let tokens = TextNormalizer.tokens("vad tycker du")
        XCTAssertNil(matcher().firstMatch(of: ["vad tycker du buddy"], in: tokens))
    }

    func testShortWordsMustMatchExactly() {
        let tokens = TextNormalizer.tokens("vad tycker då buddy")
        XCTAssertNil(matcher().firstMatch(of: ["vad tycker du buddy"], in: tokens))
    }

    func testSearchStartsAtGivenIndex() {
        let tokens = TextNormalizer.tokens("tack buddy och sedan pratar jag vidare")
        XCTAssertNotNil(matcher().firstMatch(of: ["tack buddy"], in: tokens, from: 0))
        XCTAssertNil(matcher().firstMatch(of: ["tack buddy"], in: tokens, from: 1))
    }

    func testPicksPhraseThatEndsFirst() {
        let tokens = TextNormalizer.tokens("hej buddy vad tycker du buddy")
        let match = matcher().firstMatch(of: ["vad tycker du buddy", "hej buddy"], in: tokens)
        XCTAssertEqual(match?.phrase, "hej buddy")
    }

    func testSimilarity() {
        XCTAssertEqual(PhraseMatcher.similarity("buddy", "buddy"), 1)
        XCTAssertGreaterThanOrEqual(PhraseMatcher.similarity("buddy", "baddy"), 0.75)
        XCTAssertGreaterThanOrEqual(PhraseMatcher.similarity("buddy", "budy"), 0.75)
        XCTAssertLessThan(PhraseMatcher.similarity("buddy", "kaffe"), 0.5)
    }

    func testTokenizedTextMapsTokensBackToRawWords() {
        let text = TokenizedText("Hej, AI-agenter! Vad tycker du?")
        XCTAssertEqual(text.tokens, ["hej", "ai", "agenter", "vad", "tycker", "du"])
        XCTAssertEqual(text.rawText(tokens: 1..<3), "AI-agenter!")
        XCTAssertEqual(text.rawText(tokens: 3..<6), "Vad tycker du?")
        XCTAssertEqual(text.rawText(tokens: 4..<4), "")
        XCTAssertEqual(text.rawText(tokens: 5..<99), "du?")
    }

    func testNormalizerKeepsSwedishLettersAndFoldsOthers() {
        XCTAssertEqual(TextNormalizer.tokens("Åsa Öberg och Ärla idé café"), ["åsa", "öberg", "och", "ärla", "ide", "cafe"])
        XCTAssertEqual(TextNormalizer.key("Va tycker du, Buddy?"), "vad tycker du buddy")
    }
}
