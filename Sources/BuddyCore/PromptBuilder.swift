import Foundation

/// Builds the system prompt and user turns sent to Claude.
public enum PromptBuilder {
    public static func system(session: Session, moment: Moment) -> String {
        var parts: [String] = []
        let persona = session.persona.trimmingCharacters(in: .whitespacesAndNewlines)
        parts.append(persona.isEmpty ? Session.defaultPersona : persona)

        let context = session.context.trimmingCharacters(in: .whitespacesAndNewlines)
        if !context.isEmpty {
            parts.append("## Om presentationen\n\(context)")
        }

        parts.append("""
        ## Så fungerar det
        - Du heter \(session.buddyName) och syns som en liten animerad robot i hörnet av skärmen medan talaren presenterar. Det du skriver läses upp med talsyntes för publiken.
        - Talarens repliker kommer från automatisk taligenkänning och kan innehålla felhörda ord. Tolka dem välvilligt utifrån sammanhanget.
        - Svara på svenska om inte manuset säger något annat.
        - Skriv bara det du ska säga högt: ingen markdown, inga listor, inga emojier, inga scenanvisningar och ingen text inom parentes eller asterisker.
        - Håll svaren korta och lätta att säga: högst cirka \(session.maxWordsPerReply) ord, gärna en till tre meningar.
        - Var rolig och personlig men respektfull mot talaren och publiken.
        - Hitta inte på fakta om talaren, publiken eller företag.
        """)

        var momentPart = "## Det här momentet: \(moment.title)"
        let script = moment.script.trimmingCharacters(in: .whitespacesAndNewlines)
        if script.isEmpty {
            momentPart += "\nInget manus finns. Svara naturligt på det talaren säger."
        } else {
            momentPart += """

            Ungefärligt manus för dialogen:
            \(script)

            Följ manuset i stora drag och i ordning, men formulera dig fritt och anpassa dig efter \
            det talaren faktiskt säger. Om talaren går utanför manuset, svara naturligt och styr gärna tillbaka.
            """
        }
        let lines = moment.lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !lines.isEmpty {
            momentPart += "\n\nRepliker du kan använda, ordagrant eller fritt:\n" + lines.map { "- \($0)" }.joined(separator: "\n")
        }
        parts.append(momentPart)
        return parts.joined(separator: "\n\n")
    }

    /// The user turn that opens a moment.
    public static func opening(background: String, utterance: String, manual: Bool, turn: Int, maxTurns: Int) -> String {
        var s = ""
        let bg = background.trimmingCharacters(in: .whitespacesAndNewlines)
        if !bg.isEmpty {
            s += "[Det här har talaren pratat om precis innan]\n\(bg)\n\n"
        }
        let said = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        if manual || said.isEmpty {
            s += "[Talaren har tagit in dig i samtalet. Börja enligt manuset.]"
        } else {
            s += "[Talaren vänder sig till dig och säger]\n\(said)"
        }
        s += "\n\n" + turnNote(turn: turn, maxTurns: maxTurns)
        return s
    }

    /// A user turn later in the dialog.
    public static func followUp(utterance: String, turn: Int, maxTurns: Int) -> String {
        "[Talaren säger]\n\(utterance.trimmingCharacters(in: .whitespacesAndNewlines))\n\n" + turnNote(turn: turn, maxTurns: maxTurns)
    }

    static func turnNote(turn: Int, maxTurns: Int) -> String {
        if maxTurns <= 0 {
            return "[Not: Talaren avslutar dialogen när hen vill.]"
        }
        if turn >= maxTurns {
            return "[Not: Det här är ditt sista svar i det här momentet. Runda av och lämna tillbaka ordet till talaren.]"
        }
        return "[Not: Det här är ditt svar \(turn) av högst \(maxTurns).]"
    }
}
