import Foundation

/// Turns transcribed speech into comparable tokens.
public enum TextNormalizer {
    /// Spoken/colloquial Swedish forms mapped to one canonical token, so that
    /// "va tycker du" matches the phrase "vad tycker du".
    public static let colloquial: [String: String] = [
        "va": "vad", "mej": "mig", "dej": "dig", "sej": "sig",
        "dom": "de", "dem": "de", "nåt": "något", "nånting": "något", "nån": "någon",
        "nåra": "några", "sen": "sedan", "å": "och", "o": "och", "ok": "okej",
        "okay": "okej", "tackar": "tack",
    ]

    private static let swedishLetters: Set<Character> = ["å", "ä", "ö"]

    /// Lowercases, folds foreign diacritics (but keeps å, ä, ö) and splits into word tokens.
    public static func tokens(_ text: String) -> [String] {
        words(text).flatMap(tokens(forWord:))
    }

    /// Whitespace-separated words of the raw text.
    public static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// Normalized tokens for a single raw word ("AI-agenter," -> ["ai", "agenter"]).
    public static func tokens(forWord word: String) -> [String] {
        var current = ""
        var out: [String] = []
        for ch in word.lowercased() {
            if ch.isLetter || ch.isNumber {
                if swedishLetters.contains(ch) {
                    current.append(ch)
                } else {
                    current += String(ch).folding(options: [.diacriticInsensitive], locale: nil)
                }
            } else if !current.isEmpty {
                out.append(current)
                current = ""
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Normalized phrase as a single string, used to compare phrases with each other.
    public static func key(_ phrase: String) -> String {
        tokens(phrase).map { colloquial[$0] ?? $0 }.joined(separator: " ")
    }
}

/// Raw text plus its normalized tokens, with a map back to the raw words.
public struct TokenizedText: Equatable, Sendable {
    public let raw: String
    public let words: [String]
    public let tokens: [String]
    /// For each token, the index of the raw word it came from.
    public let tokenToWord: [Int]

    public init(_ raw: String) {
        self.raw = raw
        let words = TextNormalizer.words(raw)
        var tokens: [String] = []
        var map: [Int] = []
        for (i, w) in words.enumerated() {
            for t in TextNormalizer.tokens(forWord: w) {
                tokens.append(t)
                map.append(i)
            }
        }
        self.words = words
        self.tokens = tokens
        self.tokenToWord = map
    }

    public static let empty = TokenizedText("")

    /// The raw words covering the given token range, joined by spaces.
    public func rawText(tokens range: Range<Int>) -> String {
        let lower = max(0, range.lowerBound)
        let upper = min(tokens.count, range.upperBound)
        guard lower < upper else { return "" }
        let first = tokenToWord[lower]
        let last = tokenToWord[upper - 1]
        return words[first...last].joined(separator: " ")
    }
}

public struct PhraseMatch: Equatable, Sendable {
    /// The phrase as written in the configuration.
    public let phrase: String
    /// Token range in the searched text (absolute indices).
    public let range: Range<Int>
    public let score: Double
}

/// Fuzzy, in-order matching of short phrases against a stream of recognized words.
public struct PhraseMatcher: Sendable {
    /// Minimum per-word similarity (0...1) for a word to count as a match.
    public var threshold: Double
    /// How many extra recognized words may sit between two words of a phrase ("vad tycker eh du").
    public var maxGap: Int
    /// Extra spellings mapped to a canonical token (e.g. "baddy" -> "buddy").
    public var aliases: [String: String]

    public init(threshold: Double = 0.75, maxGap: Int = 1, aliases: [String: String] = [:]) {
        self.threshold = threshold
        self.maxGap = maxGap
        self.aliases = aliases
    }

    /// Builds a matcher that treats the session's name variants as the Buddy name.
    public static func forSession(_ session: Session, threshold: Double) -> PhraseMatcher {
        var aliases: [String: String] = [:]
        let nameTokens = TextNormalizer.tokens(session.buddyName)
        if nameTokens.count == 1, let name = nameTokens.first {
            for variant in session.nameVariants {
                for v in TextNormalizer.tokens(variant) where v != name {
                    aliases[v] = name
                }
            }
        }
        return PhraseMatcher(threshold: threshold, maxGap: 1, aliases: aliases)
    }

    func canonical(_ token: String) -> String {
        if let a = aliases[token] { return a }
        return TextNormalizer.colloquial[token] ?? token
    }

    /// Finds the phrase whose match ends earliest in `tokens[start...]`.
    /// Ties prefer the longer (more specific) phrase, then the better score.
    public func firstMatch(of phrases: [String], in tokens: [String], from start: Int = 0) -> PhraseMatch? {
        guard start < tokens.count else { return nil }
        let text = tokens.map(canonical)
        var best: PhraseMatch?
        for phrase in phrases {
            let p = TextNormalizer.tokens(phrase).map(canonical)
            guard !p.isEmpty, let m = match(p, in: text, from: start) else { continue }
            let candidate = PhraseMatch(phrase: phrase, range: m.range, score: m.score)
            if let b = best {
                if candidate.range.upperBound < b.range.upperBound
                    || (candidate.range.upperBound == b.range.upperBound && candidate.range.count > b.range.count)
                    || (candidate.range.upperBound == b.range.upperBound && candidate.range.count == b.range.count
                        && candidate.score > b.score) {
                    best = candidate
                }
            } else {
                best = candidate
            }
        }
        return best
    }

    private func match(_ phrase: [String], in text: [String], from start: Int) -> (range: Range<Int>, score: Double)? {
        var bestEnd = Int.max
        var result: (Range<Int>, Double)?
        var i = start
        while i < text.count {
            let s0 = similarity(phrase[0], text[i])
            if s0 >= requiredScore(for: phrase[0]) {
                var total = s0
                var j = i + 1
                var ok = true
                for p in phrase.dropFirst() {
                    var found = false
                    var k = j
                    while k < min(text.count, j + maxGap + 1) {
                        let s = similarity(p, text[k])
                        if s >= requiredScore(for: p) {
                            total += s
                            j = k + 1
                            found = true
                            break
                        }
                        k += 1
                    }
                    if !found { ok = false; break }
                }
                if ok, j < bestEnd {
                    bestEnd = j
                    result = (i..<j, total / Double(phrase.count))
                }
            }
            i += 1
        }
        return result.map { (range: $0.0, score: $0.1) }
    }

    /// Short words must match exactly; longer words may differ a little.
    func requiredScore(for phraseToken: String) -> Double {
        phraseToken.count <= 3 ? 1.0 : threshold
    }

    /// 0...1 similarity based on edit distance. Doubled letters are also compared
    /// collapsed, so "baddy" and "budy" are close.
    public static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        return max(ratio(a, b), ratio(collapse(a), collapse(b)))
    }

    func similarity(_ a: String, _ b: String) -> Double {
        PhraseMatcher.similarity(a, b)
    }

    static func collapse(_ s: String) -> String {
        var out = ""
        var last: Character?
        for ch in s where ch != last {
            out.append(ch)
            last = ch
        }
        return out
    }

    static func ratio(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        let longest = max(x.count, y.count)
        if longest == 0 { return 1 }
        return 1 - Double(levenshtein(x, y)) / Double(longest)
    }

    static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = Array(repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
