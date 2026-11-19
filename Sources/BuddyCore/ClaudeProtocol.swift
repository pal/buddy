import Foundation

public struct ChatMessage: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable {
        case user, assistant
    }

    public var role: Role
    public var text: String

    public init(role: Role, text: String) {
        self.role = role
        self.text = text
    }
}

/// Everything needed to ask for one Buddy reply.
public struct ReplyRequest: Equatable, Sendable {
    public var system: String
    public var messages: [ChatMessage]

    public init(system: String, messages: [ChatMessage]) {
        self.system = system
        self.messages = messages
    }
}

/// Something that streams reply text for a request (Claude in the app, a fake in tests).
public protocol ReplyGenerator: AnyObject {
    func streamReply(_ request: ReplyRequest) -> AsyncThrowingStream<String, Error>
}

/// An alternating user/assistant history that always starts with the user.
public struct Conversation: Equatable, Sendable {
    public private(set) var messages: [ChatMessage] = []

    public init() {}

    public mutating func appendUser(_ text: String) {
        append(.user, text)
    }

    public mutating func appendAssistant(_ text: String) {
        guard !messages.isEmpty else { return }
        append(.assistant, text)
    }

    private mutating func append(_ role: ChatMessage.Role, _ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let last = messages.last, last.role == role {
            messages[messages.count - 1].text = last.text + "\n\n" + trimmed
        } else {
            messages.append(ChatMessage(role: role, text: trimmed))
        }
    }
}

/// Builds Messages API request bodies and parses its server-sent events.
public enum ClaudeAPI {
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let apiVersion = "2026-10-21"
    public static let fallbackBeta = "server-side-fallback-2026-07-01"
    public static let defaultModel = "claude-opus-5-5"

    public struct ModelOption: Identifiable, Hashable, Sendable {
        public let id: String
        public let label: String
    }

    public static let modelOptions: [ModelOption] = [
        ModelOption(id: "claude-opus-5-5", label: "Claude Opus 5.5 (standard, smartast)"),
        ModelOption(id: "claude-sonnet-5-5", label: "Claude Sonnet 5.5 (snabbare)"),
        ModelOption(id: "claude-haiku-5-5", label: "Claude Haiku 5.5 (snabbast, billigast)"),
    ]

    /// Models that accept server-side refusal fallbacks (`fallbacks: "default"`).
    public static func supportsServerFallback(_ model: String) -> Bool {
        model.hasPrefix("claude-opus-5") || model.hasPrefix("claude-sonnet-5-5") || model.hasPrefix("claude-fable-5")
    }

    public static func headers(apiKey: String, model: String) -> [String: String] {
        var h = [
            "content-type": "application/json",
            "x-api-key": apiKey,
            "anthropic-version": apiVersion,
        ]
        if supportsServerFallback(model) {
            h["anthropic-beta"] = fallbackBeta
        }
        return h
    }

    /// JSON body for a streamed Messages request. Spoken replies are short, so effort is low
    /// to keep latency down; thinking stays at the model's adaptive default.
    public static func body(model: String, request: ReplyRequest, maxTokens: Int = 4000, effort: String = "low") throws -> Data {
        var json: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "stream": true,
            "system": request.system,
            "messages": request.messages.map { ["role": $0.role.rawValue, "content": $0.text] },
            "output_config": ["effort": effort],
        ]
        if supportsServerFallback(model) {
            json["fallbacks"] = "default"
        }
        return try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    }

    public enum StreamEvent: Equatable, Sendable {
        case text(String)
        case stopReason(String)
        case messageStop
        case error(String)
        case ignored
    }

    /// Parses one `data:` line of the SSE stream.
    public static func parse(sseLine line: String) -> StreamEvent {
        guard line.hasPrefix("data:") else { return .ignored }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String
        else { return .ignored }

        switch type {
        case "content_block_delta":
            if let delta = obj["delta"] as? [String: Any],
               delta["type"] as? String == "text_delta",
               let text = delta["text"] as? String {
                return .text(text)
            }
            return .ignored
        case "message_delta":
            if let delta = obj["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String {
                return .stopReason(reason)
            }
            return .ignored
        case "message_stop":
            return .messageStop
        case "error":
            let message = (obj["error"] as? [String: Any])?["message"] as? String ?? "Okänt fel"
            return .error(message)
        default:
            return .ignored
        }
    }

    /// Extracts a readable message from a non-200 JSON error body.
    public static func errorMessage(from data: Data, status: Int) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = obj["error"] as? [String: Any],
           let msg = err["message"] as? String {
            return "HTTP \(status): \(msg)"
        }
        return "HTTP \(status)"
    }
}
