import AppKit
import CoreServices
import Darwin
import Foundation
import BuddyCore

/// Offers to move Buddy to the Applications folder when it runs from somewhere else, for example
/// straight from Downloads as "Buddy 3". There it is always called Buddy.app, replaces an older
/// Buddy and can update itself. The downloaded copy goes to the Trash.
@MainActor
enum AppMover {
    enum Answer: String {
        case confirm, later, never
    }

    /// Where this copy is and where it would go.
    struct Location {
        /// This copy as the process sees it: a read-only mirror under App Translocation for a fresh download.
        let app: URL
        /// Where this copy really is, or nil when that cannot be found out.
        let original: URL?
        /// The Applications folder to install into.
        let folder: URL
        /// The folder as it reads in a sentence.
        let folderText: String
        let installed: Bool
    }

    private static let suppressKey = "moveToApplicationsSuppressed"

    /// Called first thing at launch. `completion(true)` means Buddy is moving: it quits and the copy
    /// in the Applications folder starts instead.
    static func offerIfNeeded(completion: @escaping (Bool) -> Void) {
        let options = LaunchOptions.current
        guard !options.isTesting || options.applicationsFolder != nil,
              let location = currentLocation(), !location.installed,
              !defaults.bool(forKey: suppressKey)
        else { return completion(false) }
        offer(location, allowSuppression: true, completion: completion)
    }

    /// From the settings, also after "Fråga inte igen".
    static func offerFromSettings() {
        guard let location = currentLocation(), !location.installed else { return }
        offer(location, allowSuppression: false) { _ in }
    }

    static var isInstalled: Bool { currentLocation()?.installed ?? true }

    static func currentLocation() -> Location? {
        let app = Bundle.main.bundleURL
        guard app.pathExtension == "app" else { return nil }
        let fileManager = FileManager.default
        let original = originalURL(of: app)
        let folders: [URL]
        let folder: URL
        let folderText: String
        if let override = LaunchOptions.current.applicationsFolder {
            folders = [override]
            folder = override
            folderText = "mappen Program"
        } else {
            folders = fileManager.urls(for: .applicationDirectory, in: .allDomainsMask)
            let shared = URL(fileURLWithPath: "/Applications", isDirectory: true)
            if fileManager.isWritableFile(atPath: shared.path) {
                folder = shared
                folderText = "mappen Program"
            } else {
                folder = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
                folderText = "mappen Program i din hemmapp"
            }
        }
        let installed = InstallLocation.isInstalled((original ?? app).path, applicationsFolders: folders.map(\.path))
        return Location(app: app, original: original, folder: folder, folderText: folderText, installed: installed)
    }

    /// A fresh download runs from a read-only mirror (App Translocation). Returns where it really
    /// is, the app itself when it is not translocated, or nil when that cannot be found out.
    static func originalURL(of app: URL) -> URL? {
        guard app.path.contains("/AppTranslocation/") else { return app }
        typealias OriginalPath = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let symbol = dlsym(security, "SecTranslocateCreateOriginalPathForURL")
        else { return nil }
        let function = unsafeBitCast(symbol, to: OriginalPath.self)
        guard let original = function(app as CFURL, nil)?.takeRetainedValue() else { return nil }
        return original as URL
    }

    // MARK: Asking

    private static func offer(_ location: Location, allowSuppression: Bool, completion: @escaping (Bool) -> Void) {
        guard let destination = destination(in: location.folder) else {
            EventLog.shared.record("moveError", ["message": "other apps are called Buddy in \(location.folder.path)"])
            return completion(false)
        }
        let current = info(of: location.app)?["CFBundleShortVersionString"] as? String ?? "0"
        let installedVersion: String? = FileManager.default.fileExists(atPath: destination.path)
            ? (info(of: destination)?["CFBundleShortVersionString"] as? String ?? "")
            : nil
        let plan = InstallLocation.plan(current: current, installedVersion: installedVersion)
        let others = otherInstances()
        let trash = canTrash(location.original, destination: destination)
        let prompt = MovePrompt.make(plan: plan, current: current, folder: location.folderText,
                                     othersRunning: !others.isEmpty, trashesThisCopy: trash)
        let planName: String
        switch plan {
        case .install: planName = "install"
        case .openInstalled: planName = "openInstalled"
        }
        EventLog.shared.record("movePrompt", [
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "plan": planName,
            "title": prompt.title,
            "message": prompt.message,
            "buttons": [prompt.confirm, prompt.cancel],
            "from": (location.original ?? location.app).path,
            "to": destination.path,
            "version": current,
            "installedVersion": installedVersion.map { $0 as Any } ?? NSNull(),
            "running": others.map { Int($0.processIdentifier) },
        ])

        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.informativeText = prompt.message
        alert.addButton(withTitle: prompt.confirm)
        alert.addButton(withTitle: prompt.cancel)
        if allowSuppression {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = MovePrompt.suppression
        }
        ask(alert) { answer in
            switch answer {
            case .confirm:
                completion(perform(plan, location: location, destination: destination, trash: trash))
            case .later, .never:
                if answer == .never {
                    defaults.set(true, forKey: suppressKey)
                }
                EventLog.shared.record("moveDeclined", ["suppress": answer == .never])
                completion(false)
            }
        }
    }

    private static func ask(_ alert: NSAlert, completion: @escaping (Answer) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        alert.window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        if let automatic = LaunchOptions.current.settingOverrides["moveToApplications"].flatMap(Answer.init(rawValue:)) {
            // Tests answer for the user, after showing the question long enough for a screenshot.
            alert.layout()
            let window = alert.window
            window.level = .modalPanel
            window.center()
            window.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                window.orderOut(nil)
                completion(automatic)
            }
            return
        }
        if alert.runModal() == .alertFirstButtonReturn {
            completion(.confirm)
        } else {
            completion(alert.suppressionButton?.state == .on ? .never : .later)
        }
    }

    // MARK: Moving

    /// Returns true when Buddy quits for the copy in the Applications folder.
    private static func perform(_ plan: InstallLocation.Plan, location: Location, destination: URL, trash: Bool) -> Bool {
        switch plan {
        case .openInstalled(let version):
            let running = otherInstances().first { $0.bundleURL?.standardizedFileURL == destination.standardizedFileURL }
            let trashed = trash && moveToTrash(location.original)
            EventLog.shared.record("moveOpenInstalled", [
                "path": destination.path,
                "version": version,
                "trashed": trashed,
                "alreadyRunning": running != nil,
            ])
            if let running {
                _ = running.activate(options: [])
            } else {
                Updater.relaunch(destination)
            }
            quit()
            return true
        case .install(let replacing):
            do {
                let stopped = quitOtherInstances()
                try install(location.app, at: destination)
                let trashed = trash && moveToTrash(location.original)
                EventLog.shared.record("moveToApplications", [
                    "from": (location.original ?? location.app).path,
                    "to": destination.path,
                    "replaced": replacing != nil,
                    "quitOthers": stopped,
                    "trashed": trashed,
                ])
                Updater.relaunch(destination)
                quit()
                return true
            } catch {
                EventLog.shared.record("moveError", ["message": error.localizedDescription])
                showError(error)
                return false
            }
        }
    }

    /// Copies this app next to the destination, then swaps it in, so a failed copy never leaves a
    /// broken Buddy behind.
    private static func install(_ app: URL, at destination: URL) throws {
        let fileManager = FileManager.default
        let folder = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let staging: URL
        do {
            staging = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                          appropriateFor: folder, create: true)
        } catch {
            staging = folder.appendingPathComponent(".Buddy-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        }
        defer { try? fileManager.removeItem(at: staging) }
        let copy = staging.appendingPathComponent(destination.lastPathComponent)
        try fileManager.copyItem(at: app, to: copy)
        removeQuarantine(copy)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: copy, backupItemName: nil, options: [])
        } else {
            try fileManager.moveItem(at: copy, to: destination)
        }
        _ = LSRegisterURL(destination as CFURL, true)
    }

    /// A copy keeps the download's quarantine flag, so macOS would run it from a read-only mirror
    /// (App Translocation) where it cannot update itself. The user has already opened this download.
    private static func removeQuarantine(_ app: URL) {
        var paths = [app.path]
        if let files = FileManager.default.enumerator(atPath: app.path) {
            for case let file as String in files {
                paths.append(app.appendingPathComponent(file).path)
            }
        }
        for path in paths {
            _ = removexattr(path, "com.apple.quarantine", XATTR_NOFOLLOW)
        }
    }

    /// Quits the other running Buddy, politely first. Returns how many there were.
    private static func quitOtherInstances() -> Int {
        let others = otherInstances()
        guard !others.isEmpty else { return 0 }
        others.forEach { _ = $0.terminate() }
        if !waitUntilGone(others, seconds: 5) {
            others.filter { isRunning($0) }.forEach { _ = $0.forceTerminate() }
            _ = waitUntilGone(others, seconds: 2)
        }
        return others.count
    }

    private static func otherInstances() -> [NSRunningApplication] {
        guard let identifier = Bundle.main.bundleIdentifier else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .filter { $0.processIdentifier != me && isRunning($0) }
    }

    private static func isRunning(_ app: NSRunningApplication) -> Bool {
        !app.isTerminated && kill(app.processIdentifier, 0) == 0
    }

    private static func waitUntilGone(_ apps: [NSRunningApplication], seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while apps.contains(where: { isRunning($0) }) {
            if Date() > deadline { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return true
    }

    private static func moveToTrash(_ url: URL?) -> Bool {
        guard let url else { return false }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            return true
        } catch {
            EventLog.shared.record("moveTrashError", ["message": error.localizedDescription, "path": url.path])
            return false
        }
    }

    private static func quit() {
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }

    private static func showError(_ error: Error) {
        guard LaunchOptions.current.settingOverrides["moveToApplications"] == nil else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Buddy kunde inte flyttas"
        alert.informativeText = "\(error.localizedDescription)\n\nBuddy startar härifrån i stället. Du kan också dra Buddy till mappen Program i Finder."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: Helpers

    /// Buddy.app in the folder, unless a different app already has that name.
    private static func destination(in folder: URL) -> URL? {
        let ours = Bundle.main.bundleIdentifier ?? ""
        let name = InstallLocation.destinationName(ourID: ours) { name in
            let url = folder.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return info(of: url)?["CFBundleIdentifier"] as? String ?? ""
        }
        return name.map { folder.appendingPathComponent($0) }
    }

    private static func canTrash(_ original: URL?, destination: URL) -> Bool {
        guard let original, original.standardizedFileURL != destination.standardizedFileURL else { return false }
        let readOnly = (try? original.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        return !readOnly
    }

    nonisolated private static func info(of app: URL) -> [String: Any]? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
    }

    private static var defaults: UserDefaults {
        LaunchOptions.current.isTesting ? (UserDefaults(suiteName: AppSettings.testDomain) ?? .standard) : .standard
    }
}
