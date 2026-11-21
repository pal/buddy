import Foundation

/// ElevenLabs v3 and v4 read bracketed English "audio tags" such as [laughs] as directions
/// for the delivery. Buddy allows a small set of them; other voices and the subtitles get
/// the text without tags.
public enum AudioTags {
    /// The tags Buddy may use, in the form the prompt asks for.
    public static let allowed: [String] = [
        "laughs", "chuckles", "sighs", "whispers", "excited", "curious", "mischievously", "surprised",
    ]

    /// Other spellings, including Swedish ones, mapped to an allowed tag.
    static let synonyms: [String: String] = [
        "laugh": "laughs", "laughing": "laughs", "giggles": "chuckles", "giggle": "chuckles",
        "chuckle": "chuckles", "chuckling": "chuckles", "sigh": "sighs", "sighing": "sighs",
        "whisper": "whispers", "whispering": "whispers", "excitedly": "excited", "curiously": "curious",
        "mischievous": "mischievously", "surprise": "surprised",
        "skrattar": "laughs", "skratt": "laughs", "fnissar": "chuckles", "småskrattar": "chuckles",
        "suckar": "sighs", "suck": "sighs", "viskar": "whispers", "viskande": "whispers",
        "ivrigt": "excited", "ivrig": "excited", "entusiastiskt": "excited", "nyfiket": "curious",
        "nyfiken": "curious", "busigt": "mischievously", "förvånat": "surprised", "förvånad": "surprised",
    ]

    private static let bracketed = try! NSRegularExpression(pattern: #"\[([^\[\]]{1,80})\]"#)

    /// The allowed tag for the text inside a bracket, or nil.
    public static func canonical(_ inner: String) -> String? {
        let word = inner.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if allowed.contains(word) { return word }
        return synonyms[word]
    }

    /// Keeps allowed tags as "[laughs]" and removes any other bracketed text.
    public static func normalize(_ text: String) -> String {
        replaceTags(in: text) { inner in canonical(inner).map { "[\($0)]" } ?? " " }
    }

    /// Removes all bracketed tags, for subtitles and voices that would read them aloud.
    public static func strip(_ text: String) -> String {
        replaceTags(in: text) { _ in " " }
    }

    public static func contains(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return bracketed.firstMatch(in: text, range: range) != nil
    }

    private static func replaceTags(in text: String, with replacement: (String) -> String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        var result = ""
        var last = text.startIndex
        for match in bracketed.matches(in: text, range: range) {
            guard let whole = Range(match.range, in: text), let inner = Range(match.range(at: 1), in: text) else { continue }
            result += text[last..<whole.lowerBound]
            result += replacement(String(text[inner]))
            last = whole.upperBound
        }
        result += text[last...]
        return collapse(result)
    }

    private static func collapse(_ text: String) -> String {
        var s = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        // No space before punctuation left behind by a removed tag ("Hej [x]!" → "Hej!").
        s = s.replacingOccurrences(of: #" ([.,!?…;:])"#, with: "$1", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
