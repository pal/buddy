import AppKit
import CoreServices
import Foundation
import Security
import BuddyCore

/// Keeps Buddy up to date. Once a day it asks GitHub for the latest release, downloads
/// Buddy.zip next to the installed app and checks it: same bundle, the expected version,
/// signed by the same Developer ID team as this copy, and accepted by Gatekeeper
/// (notarized). The new version is installed when Buddy has not been used for a while, or
/// when Buddy quits, and never in the middle of a dialog.
@MainActor
final class Updater: ObservableObject {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case downloading(String)
        /// Downloaded and verified; installs when Buddy is idle or quits.
        case ready(String)
        /// A newer version exists, but this copy cannot replace itself.
        case available(String, reason: String)
        case installing(String)
        case failed(String)
    }

    enum UpdateError: LocalizedError {
        case http(Int)
        case noApp
        case wrongApp(String)
        case signature(String)
        case tool(String, String)

        var errorDescription: String? {
            switch self {
            case .http(let status): return "GitHub svarade \(status)"
            case .noApp: return "Buddy.app saknas i den nedladdade filen"
            case .wrongApp(let detail): return "Den nedladdade appen är inte rätt version av Buddy (\(detail))"
            case .signature(let detail): return "Signaturen godkändes inte: \(detail)"
            case .tool(let tool, let output): return "\(tool) misslyckades: \(output)"
            }
        }
    }

    static let defaultFeed = URL(string: "https://api.github.com/repos/pal/buddy/releases/latest")!

    @Published private(set) var status: Status = .idle
    @Published private(set) var lastCheck: Date?

    let currentVersion: String
    /// True while installing would disturb: a dialog, speech, or an open window.
    var isBusy: () -> Bool = { true }
    var lastActivity: () -> Date = { Date() }
    var quitApp: () -> Void = { NSApp.terminate(nil) }

    private let settings: AppSettings
    private let feedURL: URL
    private let bundleURL = Bundle.main.bundleURL
    private var timer: Timer?
    private var checking = false
    private var readyApp: URL?
    private var readyVersion: String?

    init(settings: AppSettings) {
        self.settings = settings
        currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        feedURL = LaunchOptions.current.updateFeedURL ?? Updater.defaultFeed
        lastCheck = settings.lastUpdateCheck
    }

    /// Checks shortly after launch (if a day has passed) and then every half hour whether a
    /// check is due or a downloaded update can be installed.
    func start() {
        let overrides = LaunchOptions.current.settingOverrides
        let delay = overrides["updateCheckDelay"].flatMap(Double.init) ?? 60
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            Task { @MainActor in await self?.tick() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
    }

    private func tick() async {
        guard settings.autoUpdate else { return }
        if UpdatePolicy.isCheckDue(now: Date(), lastCheck: lastCheck) {
            await check()
        }
        maybeInstall()
    }

    /// Also called every minute by the app, so a ready update installs soon after Buddy goes idle.
    func maybeInstall() {
        guard settings.autoUpdate, readyApp != nil else { return }
        let overrides = LaunchOptions.current.settingOverrides
        let idle = overrides["updateIdleMinutes"].flatMap(Double.init).map { $0 * 60 } ?? UpdatePolicy.idleBeforeInstall
        guard UpdatePolicy.canInstallNow(now: Date(), lastActivity: lastActivity(), busy: isBusy(), idle: idle) else { return }
        install(relaunch: true)
    }

    var statusText: String {
        switch status {
        case .idle: return "Inte kontrollerat än"
        case .checking: return "Söker efter uppdateringar…"
        case .upToDate: return "Buddy är uppdaterad."
        case .downloading(let version): return "Laddar ner version \(version)…"
        case .ready(let version):
            return "Version \(version) är nedladdad och installeras när Buddy inte har använts på en stund, eller när du avslutar Buddy."
        case .available(let version, let reason): return "Version \(version) finns. \(reason)"
        case .installing(let version): return "Installerar version \(version)…"
        case .failed(let message): return "Uppdateringen misslyckades: \(message)"
        }
    }

    var readyToInstall: Bool {
        if case .ready = status { return true }
        return false
    }

    // MARK: Checking and downloading

    func check() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        status = .checking
        let now = Date()
        lastCheck = now
        settings.lastUpdateCheck = now
        do {
            let release = try await fetchRelease()
            let latest = release.version.description
            let newer = AppVersion(currentVersion).map { $0 < release.version } ?? false
            EventLog.shared.record("updateCheck", ["current": currentVersion, "latest": latest, "available": newer])
            guard newer else {
                status = .upToDate
                return
            }
            if readyVersion == latest, readyApp != nil {
                status = .ready(latest)
                return
            }
            if let reason = installBlocker() {
                status = .available(latest, reason: reason)
                EventLog.shared.record("updateUnavailable", ["version": latest, "reason": reason])
                return
            }
            status = .downloading(latest)
            let app = try await download(release)
            try await verify(app, version: release.version)
            readyApp = app
            readyVersion = latest
            status = .ready(latest)
            EventLog.shared.record("updateReady", [
                "version": latest,
                "team": Updater.teamIdentifier(of: app) ?? "",
                "path": app.path,
            ])
        } catch {
            status = .failed(error.localizedDescription)
            EventLog.shared.record("updateError", ["message": error.localizedDescription])
        }
    }

    /// Why this copy cannot replace itself, or nil if it can.
    private func installBlocker() -> String? {
        if Updater.teamIdentifier(of: bundleURL) == nil {
            return "Den här kopian är inte signerad med Developer ID (ett eget bygge), så den uppdateras inte automatiskt. Ladda ner den nya versionen från Releases."
        }
        if bundleURL.path.contains("/AppTranslocation/") {
            return "Flytta Buddy till mappen Program, så kan den uppdatera sig själv."
        }
        let folder = bundleURL.deletingLastPathComponent().path
        if !FileManager.default.isWritableFile(atPath: folder) {
            return "Buddy får inte ändra i \(folder). Ladda ner den nya versionen från Releases."
        }
        return nil
    }

    private func fetchRelease() async throws -> ReleaseInfo {
        var request = URLRequest(url: feedURL)
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Buddy-updater", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError.http(status) }
        return try ReleaseInfo.parse(data)
    }

    /// Downloads and unpacks the release in a folder on the same volume as the installed app,
    /// so it can be swapped in atomically.
    private func download(_ release: ReleaseInfo) async throws -> URL {
        let folder = try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: bundleURL, create: true
        )
        let (temporary, response) = try await URLSession.shared.download(from: release.archiveURL)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError.http(status) }
        let archive = folder.appendingPathComponent("Buddy.zip")
        try FileManager.default.moveItem(at: temporary, to: archive)
        try await Updater.run("/usr/bin/ditto", ["-x", "-k", archive.path, folder.path])
        let app = folder.appendingPathComponent("Buddy.app")
        guard FileManager.default.fileExists(atPath: app.path) else { throw UpdateError.noApp }
        EventLog.shared.record("updateDownloaded", ["version": release.version.description, "path": app.path])
        return app
    }

    private func verify(_ app: URL, version: AppVersion) async throws {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any] else {
            throw UpdateError.wrongApp("Info.plist saknas")
        }
        let identifier = info["CFBundleIdentifier"] as? String ?? ""
        guard identifier == Bundle.main.bundleIdentifier else { throw UpdateError.wrongApp(identifier) }
        let found = info["CFBundleShortVersionString"] as? String ?? ""
        guard AppVersion(found) == version else { throw UpdateError.wrongApp("version \(found)") }
        try Updater.checkSignature(of: app)
        // Gatekeeper: a valid Developer ID signature and notarized by Apple.
        try await Updater.run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path])
    }

    // MARK: Installing

    /// Swaps the new version in for the installed one and, if asked, starts it.
    @discardableResult
    func install(relaunch: Bool) -> Bool {
        guard let app = readyApp, let version = readyVersion else { return false }
        readyApp = nil
        status = .installing(version)
        EventLog.shared.record("updateInstalling", ["version": version, "relaunch": relaunch])
        do {
            _ = try FileManager.default.replaceItemAt(bundleURL, withItemAt: app, backupItemName: nil, options: [])
        } catch {
            readyVersion = nil
            status = .failed("kunde inte installera: \(error.localizedDescription)")
            EventLog.shared.record("updateError", ["message": error.localizedDescription])
            return false
        }
        _ = LSRegisterURL(bundleURL as CFURL, true)
        EventLog.shared.record("updateInstalled", ["version": version, "path": bundleURL.path])
        if relaunch {
            Updater.relaunch(bundleURL)
            quitApp()
        }
        return true
    }

    /// Installs a downloaded update when Buddy quits, so the next launch is the new version.
    func installOnQuitIfReady() {
        guard settings.autoUpdate, readyApp != nil else { return }
        install(relaunch: false)
    }

    // MARK: Helpers

    /// The Developer ID team that signed an app, or nil for ad-hoc signed copies.
    static func teamIdentifier(of url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: UInt32(kSecCSSigningInformation))
        guard SecCodeCopySigningInformation(code, flags, &information) == errSecSuccess,
              let dictionary = information as? [String: Any]
        else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// The new app must satisfy this app's designated requirement: same bundle identifier and
    /// signed by the same Developer ID team.
    static func checkSignature(of app: URL) throws {
        var selfCode: SecCode?
        var selfStatic: SecStaticCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode,
              SecCodeCopyStaticCode(selfCode, [], &selfStatic) == errSecSuccess, let selfStatic,
              SecCodeCopyDesignatedRequirement(selfStatic, [], &requirement) == errSecSuccess, let requirement
        else { throw UpdateError.signature("Buddys egen signatur gick inte att läsa") }
        var newCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &newCode) == errSecSuccess, let newCode else {
            throw UpdateError.signature("den nya appen gick inte att läsa")
        }
        let flags = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures) | UInt32(kSecCSStrictValidate)
            | UInt32(kSecCSCheckNestedCode))
        var error: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(newCode, flags, requirement, &error)
        guard status == errSecSuccess else {
            let detail = error.map { CFErrorCopyDescription($0.takeRetainedValue()) as String } ?? "OSStatus \(status)"
            throw UpdateError.signature(detail)
        }
    }

    /// Starts the installed app once this process has quit. The helper runs in its own
    /// session so it is not stopped together with Buddy. Test settings are passed on.
    static func relaunch(_ app: URL) {
        let script = """
        pid="$1"; app="$2"; shift 2
        for _ in $(seq 1 300); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
        exec /usr/bin/open -n "$@" "$app"
        """
        var arguments = ["-c", script, "buddy-relaunch", String(ProcessInfo.processInfo.processIdentifier), app.path]
        for (key, value) in ProcessInfo.processInfo.environment where key.hasPrefix("BUDDY_") {
            arguments += ["--env", "\(key)=\(value)"]
        }
        if !spawnDetached("/bin/sh", arguments) {
            EventLog.shared.record("updateError", ["message": "could not start the relaunch helper"])
        }
    }

    private static func spawnDetached(_ path: String, _ arguments: [String]) -> Bool {
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return false }
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(0x0400)) // POSIX_SPAWN_SETSID
        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        return posix_spawn(&pid, path, nil, &attributes, argv, environ) == 0
    }

    @discardableResult
    nonisolated static func run(_ tool: String, _ arguments: [String]) async throws -> String {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0 else {
                throw UpdateError.tool((tool as NSString).lastPathComponent, output)
            }
            return output
        }.value
    }
}
