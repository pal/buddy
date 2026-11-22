import Foundation

/// Where Buddy runs from, and what moving it to the Applications folder would do.
public enum InstallLocation {
    /// Names Buddy can have in the Applications folder. Always Buddy.app, whatever the download was
    /// called ("Buddy 3.app"), unless a different app already has that name.
    public static let appNames = ["Buddy.app", "Presentation Buddy.app"]

    /// True for an app inside an Applications folder: one of `folders`, or any folder named
    /// Applications (for example on another disk).
    public static func isInstalled(_ appPath: String, applicationsFolders folders: [String]) -> Bool {
        let app = components(appPath)
        for folder in folders {
            let prefix = components(folder)
            if !prefix.isEmpty, app.count > prefix.count, Array(app.prefix(prefix.count)) == prefix {
                return true
            }
        }
        return app.dropLast().contains("applications")
    }

    /// The name to install under. `bundleID(name)` gives the bundle identifier of the app that
    /// already has that name: nil when there is none, "" when it cannot be read. nil if every
    /// name belongs to another app.
    public static func destinationName(ourID: String, bundleID: (String) -> String?) -> String? {
        appNames.first { name in
            guard let existing = bundleID(name) else { return true }
            return existing == ourID
        }
    }

    public enum Plan: Equatable, Sendable {
        /// Copy this app to the Applications folder. `replacing` is the version of the Buddy that
        /// is there now ("" when unknown), or nil when there is none.
        case install(replacing: String?)
        /// A newer Buddy is already installed: open that one instead.
        case openInstalled(version: String)
    }

    /// `installedVersion`: nil when no Buddy is installed, "" when its version cannot be read.
    public static func plan(current: String, installedVersion: String?) -> Plan {
        guard let installedVersion else { return .install(replacing: nil) }
        if let installed = AppVersion(installedVersion), let mine = AppVersion(current), mine < installed {
            return .openInstalled(version: installed.description)
        }
        return .install(replacing: installedVersion)
    }

    private static func components(_ path: String) -> [String] {
        path.split(separator: "/").map { $0.lowercased() }
    }
}

/// The question Buddy asks before it moves itself.
public struct MovePrompt: Equatable, Sendable {
    public let title: String
    public let message: String
    public let confirm: String
    public let cancel: String

    public static let suppression = "Fråga inte igen"

    /// - folder: the destination as it reads in a sentence, e.g. "mappen Program".
    /// - othersRunning: another Buddy is running and will be quit.
    /// - trashesThisCopy: this copy goes to the Trash afterwards.
    public static func make(plan: InstallLocation.Plan, current: String, folder: String,
                            othersRunning: Bool, trashesThisCopy: Bool) -> MovePrompt {
        let trash = trashesThisCopy ? ["Den här kopian läggs i papperskorgen."] : []
        switch plan {
        case .install(let replacing):
            var sentences = ["Buddy ligger inte i \(folder). Där heter appen bara Buddy och kan uppdatera sig själv."]
            if let replacing {
                sentences.append(replacing.isEmpty
                    ? "Den Buddy som redan finns där ersätts."
                    : "Version \(replacing) som redan finns där ersätts.")
            }
            if othersRunning {
                sentences.append("Buddy som är igång avslutas först.")
            }
            return MovePrompt(
                title: "Flytta Buddy till \(folder)?",
                message: (sentences + trash).joined(separator: " "),
                confirm: "Flytta till Program",
                cancel: "Inte nu"
            )
        case .openInstalled(let version):
            let sentences = ["Version \(version) finns redan i \(folder). Den här kopian är version \(current)."]
            return MovePrompt(
                title: "Det finns en nyare Buddy i \(folder)",
                message: (sentences + trash).joined(separator: " "),
                confirm: "Öppna Buddy i Program",
                cancel: "Fortsätt med den här"
            )
        }
    }
}
