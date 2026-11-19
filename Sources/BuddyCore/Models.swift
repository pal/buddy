import Foundation

/// How Buddy produces its lines during a moment.
public enum MomentMode: String, Codable, CaseIterable, Sendable {
    /// Claude writes the replies, guided by the moment's rough script.
    case ai
    /// Buddy says `lines` word for word, one per turn, without calling Claude.
    case scripted
}

/// One occasion during a presentation where Buddy takes part in a dialog.
public struct Moment: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    /// Phrases that start this particular moment. Session-wide triggers also apply.
    public var triggers: [String]
    /// Phrases that end this moment. Session-wide end phrases also apply.
    public var endPhrases: [String]
    public var mode: MomentMode
    /// Rough script / notes for how the dialog should go (used by Claude).
    public var script: String
    /// Fixed lines: spoken verbatim in `scripted` mode, used as fallback in `ai` mode.
    public var lines: [String]
    /// Said when an end phrase is heard. Session-wide farewells are used if empty.
    public var farewells: [String]
    /// Number of Buddy replies before the moment ends by itself. 0 = until an end phrase.
    public var maxTurns: Int
    public var enabled: Bool

    public init(
        id: UUID = UUID(),
        title: String,
        triggers: [String] = [],
        endPhrases: [String] = [],
        mode: MomentMode = .ai,
        script: String = "",
        lines: [String] = [],
        farewells: [String] = [],
        maxTurns: Int = 3,
        enabled: Bool = true
    ) {
        self.id = id
        self.title = title
        self.triggers = triggers
        self.endPhrases = endPhrases
        self.mode = mode
        self.script = script
        self.lines = lines
        self.farewells = farewells
        self.maxTurns = maxTurns
        self.enabled = enabled
    }

    enum CodingKeys: String, CodingKey {
        case id, title, triggers, endPhrases, mode, script, lines, farewells, maxTurns, enabled
    }

    // Lenient decoding so hand-written JSON only needs the fields it cares about.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Moment"
        triggers = try c.decodeIfPresent([String].self, forKey: .triggers) ?? []
        endPhrases = try c.decodeIfPresent([String].self, forKey: .endPhrases) ?? []
        mode = try c.decodeIfPresent(MomentMode.self, forKey: .mode) ?? .ai
        script = try c.decodeIfPresent(String.self, forKey: .script) ?? ""
        lines = try c.decodeIfPresent([String].self, forKey: .lines) ?? []
        farewells = try c.decodeIfPresent([String].self, forKey: .farewells) ?? []
        maxTurns = try c.decodeIfPresent(Int.self, forKey: .maxTurns) ?? 3
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

/// A presentation: Buddy's persona plus the moments where it joins in.
public struct Session: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    /// Buddy's name as it is spoken, e.g. "Buddy". Used in prompts and to bias speech recognition.
    public var buddyName: String
    /// Other ways speech recognition tends to spell the name ("baddy", "body", ...).
    public var nameVariants: [String]
    /// Who Buddy is and how it talks.
    public var persona: String
    /// What the presentation is about, who the speaker and audience are.
    public var context: String
    /// Triggers that work for every moment. Starts the next moment that hasn't been done.
    public var triggers: [String]
    /// End phrases that work for every moment.
    public var endPhrases: [String]
    public var farewells: [String]
    /// Said if Claude can't be reached and the moment has no fixed line to fall back on.
    public var fallbackLines: [String]
    public var maxWordsPerReply: Int
    public var moments: [Moment]

    public init(
        id: UUID = UUID(),
        name: String,
        buddyName: String = "Buddy",
        nameVariants: [String] = Session.defaultNameVariants,
        persona: String = Session.defaultPersona,
        context: String = "",
        triggers: [String] = [],
        endPhrases: [String] = [],
        farewells: [String] = [],
        fallbackLines: [String] = Session.defaultFallbackLines,
        maxWordsPerReply: Int = 45,
        moments: [Moment] = []
    ) {
        self.id = id
        self.name = name
        self.buddyName = buddyName
        self.nameVariants = nameVariants
        self.persona = persona
        self.context = context
        self.triggers = triggers
        self.endPhrases = endPhrases
        self.farewells = farewells
        self.fallbackLines = fallbackLines
        self.maxWordsPerReply = maxWordsPerReply
        self.moments = moments
    }

    enum CodingKeys: String, CodingKey {
        case id, name, buddyName, nameVariants, persona, context, triggers, endPhrases
        case farewells, fallbackLines, maxWordsPerReply, moments
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Presentation"
        buddyName = try c.decodeIfPresent(String.self, forKey: .buddyName) ?? "Buddy"
        nameVariants = try c.decodeIfPresent([String].self, forKey: .nameVariants) ?? Session.defaultNameVariants
        persona = try c.decodeIfPresent(String.self, forKey: .persona) ?? Session.defaultPersona
        context = try c.decodeIfPresent(String.self, forKey: .context) ?? ""
        triggers = try c.decodeIfPresent([String].self, forKey: .triggers) ?? []
        endPhrases = try c.decodeIfPresent([String].self, forKey: .endPhrases) ?? []
        farewells = try c.decodeIfPresent([String].self, forKey: .farewells) ?? []
        fallbackLines = try c.decodeIfPresent([String].self, forKey: .fallbackLines) ?? Session.defaultFallbackLines
        maxWordsPerReply = try c.decodeIfPresent(Int.self, forKey: .maxWordsPerReply) ?? 45
        moments = try c.decodeIfPresent([Moment].self, forKey: .moments) ?? []
    }

    public static let defaultNameVariants = [
        "baddy", "bady", "badi", "baddie", "body", "boddy", "bodi", "budy", "buddie", "buddi",
    ]

    public static let defaultPersona = """
    Du är Buddy, en liten, söt och lite kaxig robot som är med på scen när talaren håller \
    en presentation om AI. Du är kvick, varm och nyfiken, och du har glimten i ögat. \
    Du gillar att retas lite med talaren men är alltid snäll. Du pratar svenska i talspråk, \
    med korta meningar.
    """

    public static let defaultFallbackLines = [
        "Oj, mina kretsar hakade upp sig lite där. Fortsätt du så länge!",
        "Hmm, jag behöver nog en kopp kaffe till mina processorer. Ta det du!",
    ]

    /// Moment used when a trigger is heard but every planned moment is already done.
    public func improvisationMoment() -> Moment {
        Moment(
            id: Session.improvisationID,
            title: "Improvisation",
            mode: .ai,
            script: "Inget manus. Svara kort och kul på det talaren just sa, och lämna sedan tillbaka ordet.",
            maxTurns: 1
        )
    }

    public static let improvisationID = UUID(uuidString: "00000000-0000-0000-0000-00000000B0D1")!
}

extension Session {
    /// A ready-to-run example in Swedish, created on first launch.
    public static func example() -> Session {
        Session(
            name: "Exempel: AI-föredrag",
            context: """
            Talaren håller ett föredrag om hur AI förändrar arbetslivet. Publiken är nyfikna \
            men blandade, från tekniker till chefer. Tonen är lättsam.
            """,
            triggers: ["vad tycker du buddy", "vad säger du buddy", "eller hur buddy", "hej buddy"],
            endPhrases: ["tack buddy", "tack så mycket buddy", "det räcker buddy", "vi går vidare"],
            farewells: ["Tack själv! Jag sitter här i hörnet om du behöver mig.", "Varsågod! Jag lyssnar vidare."],
            moments: [
                Moment(
                    title: "Introduktion",
                    triggers: ["vill du hälsa buddy"],
                    mode: .ai,
                    script: """
                    Buddy hälsar på publiken och presenterar sig som talarens AI-kompis.
                    Buddy skämtar om att den har läst hela internet men ändå inte förstår varför \
                    människor gillar måndagar.
                    Talaren frågar vad Buddy ska göra under föredraget. Buddy svarar att den ska \
                    hålla koll så att talaren inte överdriver vad AI kan.
                    """,
                    maxTurns: 2
                ),
                Moment(
                    title: "Kan AI ta jobben?",
                    mode: .ai,
                    script: """
                    Talaren har pratat om automatisering och frågar vad Buddy tycker.
                    Buddy säger att AI är bra på att ta över tråkiga uppgifter men dålig på \
                    att förstå människor, och att de bästa resultaten kommer när människa och AI \
                    jobbar ihop. Avsluta med en ödmjuk men rolig poäng.
                    """,
                    maxTurns: 3
                ),
                Moment(
                    title: "Avslutning",
                    triggers: ["några sista ord buddy"],
                    mode: .scripted,
                    lines: [
                        "Ja! Tack för att ni har lyssnat. Och kom ihåg: AI är ett verktyg, inte en ersättare.",
                        "Och ge talaren en applåd. Hen har jobbat hårdare än mina grafikkort i dag!",
                    ],
                    maxTurns: 2
                ),
            ]
        )
    }
}
