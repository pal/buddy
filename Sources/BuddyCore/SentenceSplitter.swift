import Foundation

/// Splits streamed text into sentences so speech can start before the whole reply has arrived.
public struct SentenceSplitter: Sendable {
    /// Sentences shorter than this are merged with the next one to avoid choppy speech.
    public var minLength: Int
    private var buffer = ""

    static let terminators: Set<Character> = [".", "!", "?", "…", ";", ":"]

    public init(minLength: Int = 18) {
        self.minLength = minLength
    }

    /// Adds streamed text and returns any sentences that are now complete.
    public mutating func feed(_ chunk: String) -> [String] {
        buffer += chunk
        var out: [String] = []
        while let cut = nextCut() {
            let sentence = buffer[..<cut].trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = String(buffer[cut...])
            let clean = SpeechText.sanitize(sentence)
            if !clean.isEmpty { out.append(clean) }
        }
        return out
    }

    /// Returns whatever is left when the stream has ended.
    public mutating func flush() -> [String] {
        let rest = SpeechText.sanitize(buffer)
        buffer = ""
        return rest.isEmpty ? [] : [rest]
    }

    private func nextCut() -> String.Index? {
        var idx = buffer.startIndex
        var length = 0
        while idx < buffer.endIndex {
            let ch = buffer[idx]
            let next = buffer.index(after: idx)
            length += 1
            if ch == "\n" {
                if !buffer[..<idx].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return next
                }
            } else if SentenceSplitter.terminators.contains(ch), next < buffer.endIndex,
                      buffer[next].isWhitespace, length >= minLength {
                return next
            }
            idx = next
        }
        return nil
    }

    /// Splits a complete text (e.g. a scripted line) into sentences.
    public static func split(_ text: String, minLength: Int = 18) -> [String] {
        var s = SentenceSplitter(minLength: minLength)
        return s.feed(text) + s.flush()
    }
}

public enum SpeechText {
    /// Removes things that shouldn't be read aloud: markdown, stage directions, emoji.
    public static func sanitize(_ text: String) -> String {
        var s = text
        // Bold markers first, so **word** keeps its word.
        s = s.replacingOccurrences(of: "**", with: "")
        s = s.replacingOccurrences(of: "__", with: "")
        // *stage directions* and (stage directions)
        s = s.replacingOccurrences(of: #"\*[^*]{1,80}\*"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\([^)]{1,80}\)"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\[[^\]]{1,80}\]"#, with: " ", options: .regularExpression)
        // Markdown markers and list bullets
        s = s.replacingOccurrences(of: #"[*_#`>]"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?m)^\s*[-•]\s+"#, with: "", options: .regularExpression)
        // Emoji and pictographs
        s = String(String.UnicodeScalarView(s.unicodeScalars.filter { scalar in
            !(scalar.properties.isEmojiPresentation || (scalar.properties.isEmoji && scalar.value > 0x238C))
        }))
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Rough word count, used to cap overly long replies.
    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}
