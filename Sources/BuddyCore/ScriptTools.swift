import Foundation

public enum ScriptTools {
    /// Lines in a dialog script spoken by `name`, e.g. "Buddy: Hej allihop!" -> "Hej allihop!".
    public static func lines(spokenBy name: String, in script: String) -> [String] {
        let speakerKey = TextNormalizer.key(name)
        guard !speakerKey.isEmpty else { return [] }
        return script.components(separatedBy: .newlines).compactMap { line in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            guard TextNormalizer.key(String(line[..<colon])) == speakerKey else { return nil }
            let text = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : text
        }
    }
}
