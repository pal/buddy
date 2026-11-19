import XCTest
@testable import BuddyCore

final class AudioTagTests: XCTestCase {
    func testKeepsAllowedTagsInCanonicalForm() {
        XCTAssertEqual(AudioTags.normalize("[Laughs] Hej [skrattar] du [dramatic pause] där!"), "[laughs] Hej [laughs] du där!")
        XCTAssertEqual(AudioTags.normalize("[ whispers ] Psst."), "[whispers] Psst.")
        XCTAssertEqual(AudioTags.normalize("[suckar] Måndag igen."), "[sighs] Måndag igen.")
    }

    func testStripRemovesTagsWithoutLeavingGaps() {
        XCTAssertEqual(AudioTags.strip("[laughs] Hej [whispers] där [sighs]!"), "Hej där!")
        XCTAssertEqual(AudioTags.strip("Ingen tagg här."), "Ingen tagg här.")
        XCTAssertEqual(AudioTags.strip("[laughs]"), "")
        XCTAssertTrue(AudioTags.contains("Hej [laughs]"))
        XCTAssertFalse(AudioTags.contains("Hej (skrattar)"))
    }

    func testSanitizeKeepsAudioTagsButNotOtherDirections() {
        XCTAssertEqual(SpeechText.sanitize("*ler* [laughs] Hej **du**! (skrattar)"), "[laughs] Hej du!")
        XCTAssertEqual(SpeechText.sanitize("[ler brett] Hej!"), "Hej!")
    }

    func testSplitterKeepsATagWithItsSentence() {
        let parts = SentenceSplitter.split("[laughs] Hej allihop! Jag är Buddy, talarens kompis. [whispers] Jag gillar måndagar.")
        XCTAssertEqual(parts, ["[laughs] Hej allihop!", "Jag är Buddy, talarens kompis.", "[whispers] Jag gillar måndagar."])
    }
}

final class ElevenLabsProtocolTests: XCTestCase {
    func testModelCapabilities() {
        XCTAssertEqual(ElevenLabsAPI.defaultModel, "eleven_v4_turbo")
        XCTAssertTrue(ElevenLabsAPI.models.contains { $0.id == ElevenLabsAPI.defaultModel })
        XCTAssertTrue(ElevenLabsAPI.supportsAudioTags("eleven_v4_turbo"))
        XCTAssertTrue(ElevenLabsAPI.supportsAudioTags("eleven_v4"))
        XCTAssertTrue(ElevenLabsAPI.supportsAudioTags("eleven_v3"))
        XCTAssertFalse(ElevenLabsAPI.supportsAudioTags("eleven_flash_v2_5"))
        XCTAssertFalse(ElevenLabsAPI.supportsAudioTags("eleven_multilingual_v2"))
        XCTAssertEqual(ElevenLabsAPI.preparedModel(for: "eleven_v4_turbo"), "eleven_v4")
        XCTAssertEqual(ElevenLabsAPI.preparedModel(for: "eleven_flash_v2_5"), "eleven_flash_v2_5")
        XCTAssertEqual(ElevenLabsAPI.languageCode(locale: "sv-SE"), "sv")
    }

    func testSpeechRequestSendsLanguageOnlyWhereSupported() throws {
        let v4 = try json(ElevenLabsAPI.speechRequest(text: "[laughs] Hej!", model: "eleven_v4_turbo", languageCode: "sv"))
        XCTAssertEqual(v4["text"] as? String, "[laughs] Hej!")
        XCTAssertEqual(v4["model_id"] as? String, "eleven_v4_turbo")
        XCTAssertEqual(v4["language_code"] as? String, "sv")

        let multilingual = try json(ElevenLabsAPI.speechRequest(text: "Hej!", model: "eleven_multilingual_v2", languageCode: "sv"))
        XCTAssertNil(multilingual["language_code"], "multilingual_v2 rejects language_code")
        XCTAssertEqual(ElevenLabsAPI.speechPath(voiceID: "abc123XYZ"), "/v1/text-to-speech/abc123XYZ")
        XCTAssertEqual(ElevenLabsAPI.speechPath(voiceID: "added-lib_1.v~2"), "/v1/text-to-speech/added-lib_1.v~2")
        XCTAssertEqual(ElevenLabsAPI.speechPath(voiceID: "a/b c"), "/v1/text-to-speech/a%2Fb%20c")
        XCTAssertEqual(ElevenLabsAPI.addVoicePath(ownerID: "owner-1", voiceID: "lib-1"), "/v1/voices/add/owner-1/lib-1")
    }

    func testFileExtensionFollowsContentType() {
        XCTAssertEqual(ElevenLabsAPI.fileExtension(contentType: "audio/mpeg"), "mp3")
        XCTAssertEqual(ElevenLabsAPI.fileExtension(contentType: "audio/wav"), "wav")
        XCTAssertEqual(ElevenLabsAPI.fileExtension(contentType: "audio/x-wav; charset=binary"), "wav")
        XCTAssertEqual(ElevenLabsAPI.fileExtension(contentType: nil), "mp3")
    }

    func testErrorMessages() {
        let quota = Data(#"{"detail":{"status":"quota_exceeded","message":"You have 0 credits left."}}"#.utf8)
        XCTAssertEqual(ElevenLabsAPI.errorMessage(data: quota, status: 401), "ElevenLabs svarade 401: You have 0 credits left.")
        let plain = Data(#"{"detail":"Not Found"}"#.utf8)
        XCTAssertEqual(ElevenLabsAPI.errorMessage(data: plain, status: 404), "ElevenLabs svarade 404: Not Found")
        let validation = Data(#"{"detail":[{"loc":["body","text"],"msg":"field required"}]}"#.utf8)
        XCTAssertEqual(ElevenLabsAPI.errorMessage(data: validation, status: 422), "ElevenLabs svarade 422: field required")
        XCTAssertEqual(ElevenLabsAPI.errorMessage(data: Data("Bad gateway".utf8), status: 502), "ElevenLabs svarade 502: Bad gateway")
        XCTAssertEqual(ElevenLabsAPI.errorMessage(data: Data(), status: 500), "ElevenLabs svarade 500")
    }

    func testParsesLibraryVoices() throws {
        let data = Data("""
        {"voices": [
          {"public_owner_id": "owner1", "voice_id": "lib1", "date_unix": 1700000000, "name": "Sanna",
           "accent": "swedish", "gender": "female", "age": "young", "descriptive": "warm", "use_case": "conversational",
           "category": "professional", "language": "sv", "locale": "sv-SE", "description": "Varm och glad röst",
           "preview_url": "https://example.com/sanna.mp3", "usage_character_count_1y": 1000,
           "usage_character_count_7d": 10, "play_api_usage_character_count_1y": 5, "cloned_by_count": 42,
           "free_users_allowed": false, "live_moderation_enabled": false, "featured": true,
           "verified_languages": [{"language": "sv", "model_id": "eleven_v4", "accent": "swedish"}],
           "is_added_by_user": true},
          {"public_owner_id": "owner2", "voice_id": "lib2", "name": "Erik"}
        ], "has_more": false, "total_count": 2}
        """.utf8)
        let voices = try ElevenLabsAPI.parseLibraryVoices(data)
        XCTAssertEqual(voices.count, 2)
        let sanna = voices[0]
        XCTAssertEqual(sanna.id, "lib1")
        XCTAssertEqual(sanna.publicOwnerID, "owner1")
        XCTAssertEqual(sanna.description, "Varm och glad röst")
        XCTAssertEqual(sanna.previewURL?.absoluteString, "https://example.com/sanna.mp3")
        XCTAssertTrue(sanna.isSwedish)
        XCTAssertTrue(sanna.isAddedByUser)
        XCTAssertFalse(sanna.freeUsersAllowed)
        XCTAssertEqual(sanna.details, "female · young · swedish · conversational")
        XCTAssertEqual(voices[1].name, "Erik")
        XCTAssertFalse(voices[1].isAddedByUser)
    }

    func testParsesMyVoicesAndFindsTheCopyOfALibraryVoice() throws {
        let data = Data("""
        {"voices": [
          {"voice_id": "premade1", "name": "Rachel", "category": "premade",
           "labels": {"accent": "american", "gender": "female"}, "available_for_tiers": [],
           "high_quality_base_model_ids": []},
          {"voice_id": "copy1", "name": "Sanna", "category": "professional",
           "labels": {"accent": "swedish", "language": "sv", "weird": 3}, "available_for_tiers": [],
           "high_quality_base_model_ids": [],
           "sharing": {"status": "copied", "original_voice_id": "lib1", "public_owner_id": "owner1"}}
        ]}
        """.utf8)
        let mine = try ElevenLabsAPI.parseMyVoices(data)
        XCTAssertEqual(mine.map(\.id), ["premade1", "copy1"])
        XCTAssertEqual(mine[0].accent, "american")
        XCTAssertEqual(mine[1].accent, "", "labels with other types are ignored instead of failing")
        XCTAssertEqual(mine[1].originalVoiceID, "lib1")
        let library = ElevenLabsAPI.Voice(id: "lib1", name: "Sanna", publicOwnerID: "owner1")
        XCTAssertEqual(ElevenLabsAPI.copy(of: library, in: mine)?.id, "copy1")
        XCTAssertNil(ElevenLabsAPI.copy(of: ElevenLabsAPI.Voice(id: "lib9", name: "X"), in: mine))
        XCTAssertEqual(ElevenLabsAPI.sorted(mine).first?.id, "premade1")
    }

    private func json(_ request: ElevenLabsAPI.SpeechRequest) throws -> [String: Any] {
        let data = try JSONEncoder().encode(request)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

@MainActor
final class AudioTagDialogTests: XCTestCase {
    func testPromptMentionsAudioTagsOnlyWhenTheVoiceCanPerformThem() {
        let session = Session.example()
        let moment = session.moments[0]
        XCTAssertFalse(PromptBuilder.system(session: session, moment: moment).contains("[laughs]"))
        let withTags = PromptBuilder.system(session: session, moment: moment, audioTags: true)
        XCTAssertTrue(withTags.contains("[laughs]"))
        XCTAssertTrue(withTags.contains("hakparentes"))
    }

    func testClaudeRepliesAreLiveAndFixedLinesAreFixed() async {
        let h = Harness()
        var settings = h.director.settings
        settings.audioTags = true
        h.director.settings = settings
        h.brain.replies = [["[laughs] Där fick du mig! ", "Jag håller med dig helt."]]
        h.say("vad tycker du buddy")
        h.wait(1.0)
        await h.settle()
        XCTAssertEqual(h.voice.spoken, ["[laughs] Där fick du mig!", "Jag håller med dig helt."])
        XCTAssertEqual(h.voice.kinds, [.live, .live])
        XCTAssertTrue(h.brain.requests.first?.system.contains("[laughs]") ?? false)
        h.finishSpeaking()

        h.say("Tack Buddy!")
        XCTAssertEqual(h.voice.spoken.last, "Hej då!")
        XCTAssertEqual(h.voice.kinds.last, .fixed, "farewells can be prepared")
        h.finishSpeaking()

        h.director.queue(h.third.id)
        h.say("vad tycker du buddy")
        h.wait(1.0)
        XCTAssertEqual(h.voice.spoken.last, "Första repliken här.")
        XCTAssertEqual(h.voice.kinds.last, .fixed, "scripted lines can be prepared")
    }
}
