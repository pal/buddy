import Foundation
import BuddyCore

/// Presentations stored as JSON files in ~/Library/Application Support/Buddy/Sessions.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    let folder: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        folder = support.appendingPathComponent("Buddy/Sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        load()
        if sessions.isEmpty {
            save(Session.example())
        }
    }

    func load() {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        sessions = files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? SessionStore.decode(Data(contentsOf: $0)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func session(withID id: String) -> Session? {
        sessions.first { $0.id.uuidString == id }
    }

    func save(_ session: Session) {
        do {
            try SessionStore.encode(session).write(to: fileURL(for: session.id), options: .atomic)
        } catch {
            NSLog("Buddy: kunde inte spara \(session.name): \(error)")
        }
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: id))
        sessions.removeAll { $0.id == id }
    }

    @discardableResult
    func createNew() -> Session {
        var session = Session(name: "Ny presentation")
        session.triggers = ["vad tycker du buddy"]
        session.endPhrases = ["tack buddy"]
        session.moments = [Moment(title: "Moment 1")]
        save(session)
        return session
    }

    @discardableResult
    func duplicate(_ id: UUID) -> Session? {
        guard var copy = sessions.first(where: { $0.id == id }) else { return nil }
        copy.id = UUID()
        copy.name += " (kopia)"
        copy.moments = copy.moments.map { moment in
            var m = moment
            m.id = UUID()
            return m
        }
        save(copy)
        return copy
    }

    /// Imports a session file. A file with the same id replaces the stored one.
    func importFile(at url: URL) throws -> Session {
        let session = try SessionStore.decode(Data(contentsOf: url))
        save(session)
        return session
    }

    func export(_ session: Session, to url: URL) throws {
        try SessionStore.encode(session).write(to: url, options: .atomic)
    }

    private func fileURL(for id: UUID) -> URL {
        folder.appendingPathComponent("\(id.uuidString).json")
    }

    static func encode(_ session: Session) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(session)
    }

    static func decode(_ data: Data) throws -> Session {
        try JSONDecoder().decode(Session.self, from: data)
    }
}
