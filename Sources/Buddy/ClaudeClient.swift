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
    /// The Messages API, or a local mock server in the end-to-end tests.
    var endpoint = ClaudeAPI.endpoint

    func streamReply(_ request: ReplyRequest) -> AsyncThrowingStream<String, Error> {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = self.model
        let endpoint = self.endpoint
        let messageCount = request.messages.count
        return AsyncThrowingStream { continuation in
            let task = Task {
                let started = Date()
                await ClaudeClient.record("claudeRequest", [
                    "model": model,
                    "url": endpoint.absoluteString,
                    "messages": messageCount,
                ])
                do {
                    guard !key.isEmpty else { throw ClaudeError.missingKey }
                    var urlRequest = URLRequest(url: endpoint)
                    urlRequest.httpMethod = "POST"
                    urlRequest.timeoutInterval = 30
                    for (name, value) in ClaudeAPI.headers(apiKey: key, model: model) {
                        urlRequest.setValue(value, forHTTPHeaderField: name)
                    }
                    urlRequest.httpBody = try ClaudeAPI.body(model: model, request: request)

                    let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    await ClaudeClient.record("claudeStatus", ["status": status])
                    guard status == 200 else {
                        var data = Data()
                        for try await byte in bytes {
                            data.append(byte)
                            if data.count > 64_000 { break }
                        }
                        throw ClaudeError.http(ClaudeAPI.errorMessage(from: data, status: status))
                    }

                    var finished = false
                    var characters = 0
                    var stopReason = ""
                    for try await line in bytes.lines {
                        switch ClaudeAPI.parse(sseLine: line) {
                        case .text(let text):
                            if characters == 0 {
                                let ms = Int(Date().timeIntervalSince(started) * 1000)
                                await ClaudeClient.record("claudeFirstText", ["ms": ms])
                            }
                            characters += text.count
                            continuation.yield(text)
                        case .stopReason(let reason):
                            stopReason = reason
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
                    await ClaudeClient.record("claudeDone", ["characters": characters, "stopReason": stopReason])
                    continuation.finish()
                } catch {
                    await ClaudeClient.record("claudeError", ["message": error.localizedDescription])
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private static func record(_ type: String, _ fields: [String: Sendable]) async {
        await MainActor.run {
            EventLog.shared.record(type, fields)
        }
    }
}
