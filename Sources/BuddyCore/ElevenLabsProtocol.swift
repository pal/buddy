import Foundation

/// A text-to-speech model offered in the settings.
public struct ElevenLabsModel: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
}

/// The parts of the ElevenLabs API that Buddy uses: models, speech requests, voices and
/// errors. Pure Foundation, so it can be unit tested; the app does the networking.
public enum ElevenLabsAPI {
    public static let baseURL = URL(string: "https://api.elevenlabs.io")!
    /// Expressive and fast enough for a live dialog (about 100 ms on ElevenLabs' servers).
    public static let defaultModel = "eleven_v4_turbo"
    public static let outputFormat = "mp3_44100_128"

    public static let models: [ElevenLabsModel] = [
        ElevenLabsModel(id: "eleven_v4_turbo", label: "Eleven v4 Turbo (rekommenderas)"),
        ElevenLabsModel(id: "eleven_v4", label: "Eleven v4 (högst kvalitet, långsammare)"),
        ElevenLabsModel(id: "eleven_flash_v2_5", label: "Eleven Flash v2.5 (snabbast)"),
        ElevenLabsModel(id: "eleven_multilingual_v2", label: "Eleven Multilingual v2"),
    ]

    /// v3 and v4 perform audio tags such as [laughs]; older models would read them aloud.
    public static func supportsAudioTags(_ model: String) -> Bool {
        model.hasPrefix("eleven_v3") || model.hasPrefix("eleven_v4")
    }

    /// Multilingual v2 rejects language_code, and the English-only models have no use for it.
    public static func acceptsLanguageCode(_ model: String) -> Bool {
        !["eleven_multilingual_v2", "eleven_flash_v2", "eleven_turbo_v2", "eleven_monolingual_v1"].contains(model)
    }

    /// Model for fixed lines rendered ahead of time, when waiting doesn't matter.
    public static func preparedModel(for model: String) -> String {
        model == "eleven_v4_turbo" ? "eleven_v4" : model
    }

    /// "sv-SE" → "sv" (ISO 639-1).
    public static func languageCode(locale: String) -> String {
        String(locale.prefix(2)).lowercased()
    }

    public struct SpeechRequest: Encodable, Equatable, Sendable {
        public let text: String
        public let modelID: String
        public let languageCode: String?

        enum CodingKeys: String, CodingKey {
            case text
            case modelID = "model_id"
            case languageCode = "language_code"
        }
    }

    public static func speechRequest(text: String, model: String, languageCode: String) -> SpeechRequest {
        let code = languageCode.isEmpty || !acceptsLanguageCode(model) ? nil : languageCode
        return SpeechRequest(text: text, modelID: model, languageCode: code)
    }

    /// RFC 3986 unreserved characters: safe in a path segment without encoding.
    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func pathSegment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    public static func speechPath(voiceID: String) -> String {
        "/v1/text-to-speech/\(pathSegment(voiceID))"
    }

    /// Adds a Voice Library voice to "My voices".
    public static func addVoicePath(ownerID: String, voiceID: String) -> String {
        "/v1/voices/add/\(pathSegment(ownerID))/\(pathSegment(voiceID))"
    }

    /// File extension for the audio in a response.
    public static func fileExtension(contentType: String?) -> String {
        let type = (contentType ?? "").lowercased()
        if type.contains("wav") || type.contains("wave") { return "wav" }
        if type.contains("aac") { return "aac" }
        return "mp3"
    }

    /// A readable message from an error response: what to do about it, in Swedish, for the errors
    /// a user can fix, otherwise ElevenLabs' own message.
    public static func errorMessage(data: Data, status: Int) -> String {
        let prefix = "ElevenLabs svarade \(status)"
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let text = String(decoding: data.prefix(200), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? prefix : "\(prefix): \(text)"
        }
        let detail = object["detail"]
        if let detail = detail as? [String: Any] {
            let message = (detail["message"] as? String) ?? (detail["status"] as? String) ?? ""
            let codes = ["code", "status", "type"].compactMap { detail[$0] as? String }
            if let explanation = explanation(codes: codes, message: message) {
                return "\(explanation) (\(prefix))"
            }
            return message.isEmpty ? prefix : "\(prefix): \(message)"
        }
        if let detail = detail as? String { return "\(prefix): \(detail)" }
        if let detail = detail as? [[String: Any]] {
            let messages = detail.compactMap { $0["msg"] as? String }
            if !messages.isEmpty { return "\(prefix): \(messages.joined(separator: "; "))" }
        }
        if let message = object["message"] as? String { return "\(prefix): \(message)" }
        return prefix
    }

    /// What the user can do about an error, for the errors that need them to act.
    static func explanation(codes: [String], message: String) -> String? {
        if codes.contains("paid_plan_required") {
            if message.lowercased().contains("library voice") {
                return "Med ElevenLabs gratisplan kan Buddy inte använda röster från Voice Library. "
                    + "Välj en av ElevenLabs egna röster under Inställningar → Röst → Välj röst… → Mina röster, "
                    + "eller byt till en betald plan på elevenlabs.io."
            }
            return "Det här kräver en betald ElevenLabs-plan: \(message)"
        }
        if codes.contains("missing_permissions") {
            return "ElevenLabs-nyckeln saknar en behörighet som Buddy behöver: \(message) "
                + "Skapa en nyckel med åtkomst till Text to Speech och Voices på elevenlabs.io."
        }
        if codes.contains("quota_exceeded") {
            return "Krediterna på ElevenLabs-kontot räcker inte: \(message)"
        }
        if codes.contains("invalid_api_key") {
            return "ElevenLabs godkänner inte API-nyckeln. Kontrollera den under Inställningar → Röst."
        }
        if codes.contains("voice_not_found") {
            return "Rösten finns inte på ElevenLabs-kontot. Välj en röst under Inställningar → Röst → Välj röst…"
        }
        return nil
    }

    // MARK: Voices

    public struct Voice: Identifiable, Equatable, Hashable, Sendable {
        public var id: String
        public var name: String
        /// Set for voices from the shared Voice Library.
        public var publicOwnerID: String?
        /// For a library voice added to "My voices": the library voice it was copied from.
        public var originalVoiceID: String?
        public var description = ""
        public var accent = ""
        public var gender = ""
        public var age = ""
        public var useCase = ""
        public var language = ""
        public var category = ""
        public var previewURL: URL?
        public var isAddedByUser = false
        public var freeUsersAllowed = true
        /// A voice from the shared Voice Library, or a copy of one in "My voices". ElevenLabs only
        /// lets paid plans use these through the API.
        public var fromLibrary = false

        /// One of ElevenLabs' own voices, which every plan can use.
        public var isPremade: Bool { category == "premade" }

        public init(id: String, name: String, publicOwnerID: String? = nil, originalVoiceID: String? = nil) {
            self.id = id
            self.name = name
            self.publicOwnerID = publicOwnerID
            self.originalVoiceID = originalVoiceID
        }

        public var isSwedish: Bool {
            language.lowercased().hasPrefix("sv") || accent.lowercased().contains("swed") || accent.lowercased().contains("sven")
        }

        /// One line for the voice picker, e.g. "kvinna · ung · svensk · berättare".
        public var details: String {
            [gender, age, accent, useCase.replacingOccurrences(of: "_", with: " ")]
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
        }
    }

    private struct LibraryResponse: Decodable {
        struct Item: Decodable {
            let voice_id: String
            let name: String
            let public_owner_id: String?
            let accent: String?
            let gender: String?
            let age: String?
            let descriptive: String?
            let use_case: String?
            let category: String?
            let language: String?
            let locale: String?
            let description: String?
            let preview_url: String?
            let free_users_allowed: Bool?
            let is_added_by_user: Bool?
        }
        let voices: [Item]
    }

    /// A JSON object of strings; anything else decodes as empty instead of failing the response.
    private struct LossyStrings: Decodable {
        let values: [String: String]

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            values = (try? container.decode([String: String].self)) ?? [:]
        }
    }

    private struct MyVoicesResponse: Decodable {
        struct Item: Decodable {
            struct Sharing: Decodable {
                let status: String?
                let original_voice_id: String?
                let public_owner_id: String?
            }
            struct VerifiedLanguage: Decodable {
                let language: String?
                let accent: String?
            }
            let voice_id: String
            let name: String
            let category: String?
            let labels: LossyStrings?
            let description: String?
            let preview_url: String?
            let sharing: Sharing?
            let verified_languages: [VerifiedLanguage]?
        }
        let voices: [Item]
    }

    /// Voices from GET /v1/shared-voices (the Voice Library).
    public static func parseLibraryVoices(_ data: Data) throws -> [Voice] {
        let response = try JSONDecoder().decode(LibraryResponse.self, from: data)
        return response.voices.map { item in
            var voice = Voice(id: item.voice_id, name: item.name, publicOwnerID: item.public_owner_id)
            voice.description = item.description ?? item.descriptive ?? ""
            voice.accent = item.accent ?? ""
            voice.gender = item.gender ?? ""
            voice.age = item.age ?? ""
            voice.useCase = item.use_case ?? ""
            voice.language = item.language ?? item.locale ?? ""
            voice.category = item.category ?? ""
            voice.previewURL = item.preview_url.flatMap(URL.init(string:))
            voice.isAddedByUser = item.is_added_by_user ?? false
            voice.freeUsersAllowed = item.free_users_allowed ?? true
            voice.fromLibrary = true
            return voice
        }
    }

    /// Voices from GET /v1/voices ("My voices", including the default ones).
    public static func parseMyVoices(_ data: Data) throws -> [Voice] {
        let response = try JSONDecoder().decode(MyVoicesResponse.self, from: data)
        return response.voices.map { item in
            var voice = Voice(
                id: item.voice_id,
                name: item.name,
                publicOwnerID: item.sharing?.public_owner_id,
                originalVoiceID: item.sharing?.original_voice_id
            )
            let labels = item.labels?.values ?? [:]
            voice.description = item.description ?? labels["description"] ?? ""
            voice.accent = labels["accent"] ?? item.verified_languages?.first?.accent ?? ""
            voice.gender = labels["gender"] ?? ""
            voice.age = labels["age"] ?? ""
            voice.useCase = labels["use_case"] ?? labels["use case"] ?? ""
            voice.language = labels["language"] ?? item.verified_languages?.first?.language ?? ""
            voice.category = item.category ?? ""
            voice.previewURL = item.preview_url.flatMap(URL.init(string:))
            voice.isAddedByUser = true
            voice.fromLibrary = item.sharing?.status?.hasPrefix("copied") ?? false
            return voice
        }
    }

    /// The voice in "My voices" that is the given library voice (or a copy of it).
    public static func copy(of libraryVoice: Voice, in mine: [Voice]) -> Voice? {
        mine.first { $0.id == libraryVoice.id || $0.originalVoiceID == libraryVoice.id }
    }

    /// Swedish voices first, then by name.
    public static func sorted(_ voices: [Voice]) -> [Voice] {
        voices.sorted { a, b in
            if a.isSwedish != b.isSwedish { return a.isSwedish }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
}
