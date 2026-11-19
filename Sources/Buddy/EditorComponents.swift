import SwiftUI

/// A titled block in a form, with optional help text.
struct Field<Content: View>: View {
    let title: String
    let help: String?
    let content: Content

    init(_ title: String, help: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.help = help
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content
            if let help {
                Text(help)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Multi-line text field with a visible border.
struct BoxedTextEditor: View {
    @Binding var text: String
    var minHeight: CGFloat = 70

    var body: some View {
        TextEditor(text: $text)
            .font(.body)
            .frame(minHeight: minHeight)
            .padding(4)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.35)))
    }
}

/// Edits a list of phrases as text, one per line.
struct LinesEditor: View {
    @Binding var lines: [String]
    var minHeight: CGFloat = 60
    @State private var text = ""

    var body: some View {
        BoxedTextEditor(text: $text, minHeight: minHeight)
            .onAppear {
                text = lines.joined(separator: "\n")
            }
            .onChange(of: text) { newValue in
                let parsed = LinesEditor.parse(newValue)
                if parsed != lines {
                    lines = parsed
                }
            }
            .onChange(of: lines) { newLines in
                if LinesEditor.parse(text) != newLines {
                    text = newLines.joined(separator: "\n")
                }
            }
    }

    static func parse(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
