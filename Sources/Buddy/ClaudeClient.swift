import Foundation
import BuddyCore

enum ClaudeError: LocalizedError {
    case missingKey
    case http(String)
    case stream(String)
    case refused

    var errorDescription: String? {
        switch self {
        case .missingKey: return "Ingen Anthropic API-nyckel (Inställningar → AI)"
        case .http(let message): return message
        case .stream(let message): return message
        case .refused: return "Claude avböjde att svara"
        }
    }
}

/// Streams Buddy's replies from the Claude Messages API.
final class ClaudeClient: ReplyGenerator {
    var apiKey = ""
    var model = ClaudeAPI.defaultModel

    func streamReply(_ request: ReplyRequest) -> AsyncThrowingStream<String, Error> {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = self.model
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !key.isEmpty else { throw ClaudeError.missingKey }
                    var urlRequest = URLRequest(url: ClaudeAPI.endpoint)
                    urlRequest.httpMethod = "POST"
                    urlRequest.timeoutInterval = 30
                    for (name, value) in ClaudeAPI.headers(apiKey: key, model: model) {
                        urlRequest.setValue(value, forHTTPHeaderField: name)
                    }
                    urlRequest.httpBody = try ClaudeAPI.body(model: model, request: request)

                    let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else {
                        var data = Data()
                        for try await byte in bytes {
                            data.append(byte)
                            if data.count > 64_000 { break }
                        }
                        throw ClaudeError.http(ClaudeAPI.errorMessage(from: data, status: status))
                    }

                    var finished = false
                    for try await line in bytes.lines {
                        switch ClaudeAPI.parse(sseLine: line) {
                        case .text(let text):
                            continuation.yield(text)
                        case .stopReason(let reason):
                            if reason == "refusal" { throw ClaudeError.refused }
                        case .messageStop:
                            finished = true
                        case .error(let message):
                            throw ClaudeError.stream(message)
                        case .ignored:
                            break
                        }
                        if finished { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
