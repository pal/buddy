import Foundation
import BuddyCore

/// Talks to the ElevenLabs API: speech, the shared Voice Library and "My voices".
@MainActor
struct ElevenLabsClient {
    let apiKey: String
    var baseURL: URL = LaunchOptions.current.elevenLabsURL ?? ElevenLabsAPI.baseURL

    enum ClientError: LocalizedError {
        case missingKey
        case missingVoice
        case api(String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .missingKey: return "ElevenLabs-nyckel saknas (Inställningar → Röst)"
            case .missingVoice: return "Välj en röst för ElevenLabs (Inställningar → Röst)"
            case .api(let message): return message
            case .invalidResponse: return "Oväntat svar från ElevenLabs"
            }
        }
    }

    /// Renders one sentence. Returns the audio and the file extension that matches it.
    func speech(_ text: String, voiceID: String, model: String, languageCode: String) async throws -> (data: Data, fileExtension: String) {
        let voice = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !voice.isEmpty else { throw ClientError.missingVoice }
        var request = try makeRequest(
            path: ElevenLabsAPI.speechPath(voiceID: voice),
            query: [URLQueryItem(name: "output_format", value: ElevenLabsAPI.outputFormat)],
            method: "POST"
        )
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(
            ElevenLabsAPI.speechRequest(text: text, model: model, languageCode: languageCode)
        )
        let (data, response) = try await send(request, label: "speech", extra: ["model": model])
        guard !data.isEmpty else { throw SpeechError.empty }
        return (data, ElevenLabsAPI.fileExtension(contentType: response.value(forHTTPHeaderField: "Content-Type")))
    }

    /// Voices in the shared Voice Library for a language, most used first.
    func libraryVoices(language: String) async throws -> [ElevenLabsAPI.Voice] {
        let request = try makeRequest(path: "/v1/shared-voices", query: [
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "page_size", value: "100"),
            URLQueryItem(name: "sort", value: "usage_character_count_1y"),
        ])
        let (data, _) = try await send(request, label: "libraryVoices")
        do {
            return try ElevenLabsAPI.parseLibraryVoices(data)
        } catch {
            throw ClientError.invalidResponse
        }
    }

    /// The account's own voices, including the default ones.
    func myVoices() async throws -> [ElevenLabsAPI.Voice] {
        let request = try makeRequest(path: "/v1/voices")
        let (data, _) = try await send(request, label: "myVoices")
        do {
            return ElevenLabsAPI.sorted(try ElevenLabsAPI.parseMyVoices(data))
        } catch {
            throw ClientError.invalidResponse
        }
    }

    /// Adds a Voice Library voice to "My voices" (unless it is there already) and returns
    /// the voice id to use for speech.
    func addLibraryVoice(_ voice: ElevenLabsAPI.Voice) async throws -> String {
        if voice.isAddedByUser {
            let mine = try await myVoices()
            if let copy = ElevenLabsAPI.copy(of: voice, in: mine) {
                return copy.id
            }
        }
        guard let owner = voice.publicOwnerID, !owner.isEmpty else { return voice.id }
        let path = "/v1/voices/add/\(Self.encode(owner))/\(Self.encode(voice.id))"
        var request = try makeRequest(path: path, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["new_name": voice.name])
        do {
            let (data, _) = try await send(request, label: "addVoice")
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = object["voice_id"] as? String, !id.isEmpty
            else { throw ClientError.invalidResponse }
            return id
        } catch {
            // Added earlier, for example on the website: use that copy.
            if let mine = try? await myVoices(), let copy = ElevenLabsAPI.copy(of: voice, in: mine) {
                return copy.id
            }
            throw error
        }
    }

    // MARK: Requests

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }

    private func makeRequest(path: String, query: [URLQueryItem] = [], method: String = "GET") throws -> URLRequest {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ClientError.missingKey }
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        guard var components = URLComponents(string: base + path) else { throw ClientError.invalidResponse }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw ClientError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        return request
    }

    private func send(_ request: URLRequest, label: String, extra: [String: Any] = [:]) async throws -> (Data, HTTPURLResponse) {
        let started = Date()
        var fields = extra
        fields["request"] = label
        fields["path"] = request.url?.path ?? ""
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            fields["status"] = status
            fields["bytes"] = data.count
            fields["ms"] = Int(Date().timeIntervalSince(started) * 1000)
            fields["contentType"] = http?.value(forHTTPHeaderField: "Content-Type") ?? ""
            EventLog.shared.record("elevenLabs", fields)
            guard let http, (200..<300).contains(status) else {
                throw ClientError.api(ElevenLabsAPI.errorMessage(data: data, status: status))
            }
            return (data, http)
        } catch let error as ClientError {
            throw error
        } catch {
            fields["error"] = error.localizedDescription
            fields["ms"] = Int(Date().timeIntervalSince(started) * 1000)
            EventLog.shared.record("elevenLabs", fields)
            throw ClientError.api("ElevenLabs gick inte att nå: \(error.localizedDescription)")
        }
    }
}
