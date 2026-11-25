import AppKit
import Combine

@main
enum BuddyApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // No Dock icon until the settings say whether Buddy has one (see AppDelegate.start).
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var windows: WindowManager?
    private var statusBar: StatusBarController?
    private var overlay: OverlayController?
    private var hotKeys: HotKeyCenter?
    private var mainMenu: MainMenu?
    private var dockSetting: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A copy started from Downloads first offers to move itself to the Applications folder.
        AppMover.offerIfNeeded { [weak self] moving in
            if !moving {
                self?.start()
            }
        }
    }

    private func start() {
        let model = AppModel()
        let windows = WindowManager(model: model)
        self.model = model
        self.windows = windows
        overlay = OverlayController(avatar: model.avatar, settings: model.settings)
        statusBar = StatusBarController(model: model, windows: windows)
        let mainMenu = MainMenu(model: model, windows: windows)
        mainMenu.install()
        self.mainMenu = mainMenu
        showDockIcon(model.settings.showInDock)
        dockSetting = model.settings.$showInDock
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] show in self?.showDockIcon(show) }

        let hotKeys = HotKeyCenter()
        let registered = [
            hotKeys.register(key: .b) { model.toggleMoment() },
            hotKeys.register(key: .period) { model.interrupt() },
            hotKeys.register(key: .l) { model.toggleListening() },
        ]
        self.hotKeys = hotKeys

        recordLaunch(model: model, hotKeysRegistered: registered.filter { $0 }.count)
        model.launch()
        if model.settings.isFirstLaunch {
            model.settings.isFirstLaunch = false
            windows.showEditor()
        }
    }

    /// A Dock icon and a place in ⌘-Tab, unless turned off in the settings. The menu bar icon is
    /// always there.
    private func showDockIcon(_ show: Bool) {
        let policy: NSApplication.ActivationPolicy = show ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        EventLog.shared.record("dockIcon", ["shown": show])
    }

    /// A click on the Dock icon, or opening Buddy again while it runs, shows a window: the
    /// control panel, or Buddy's open windows. (The avatar's overlay counts as a visible window
    /// for AppKit, so Buddy decides itself.)
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let open = NSApp.windows.filter { $0.isVisible && $0.styleMask.contains(.titled) }
        EventLog.shared.record("reopen", ["openWindows": open.map(\.title)])
        if open.isEmpty {
            windows?.showControlPanel()
        } else {
            NSApp.activate(ignoringOtherApps: true)
            open.first?.makeKeyAndOrderFront(nil)
        }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.updater.installOnQuitIfReady()
        model?.shutdown()
        EventLog.shared.record("terminate")
    }

    private func recordLaunch(model: AppModel, hotKeysRegistered: Int) {
        guard EventLog.shared.isEnabled else { return }
        let policy: String
        switch NSApp.activationPolicy() {
        case .regular: policy = "regular"
        case .accessory: policy = "accessory"
        case .prohibited: policy = "prohibited"
        @unknown default: policy = "unknown"
        }
        let voice = SystemVoice.resolveVoice(model.voiceConfig)
        EventLog.shared.record("launch", [
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "bundleID": Bundle.main.bundleIdentifier ?? "",
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            "bundlePath": Bundle.main.bundlePath,
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "activationPolicy": policy,
            "screens": NSScreen.screens.map { EventLog.frame($0.frame) },
            "hotKeysRegistered": hotKeysRegistered,
            "session": model.activeSession.name,
            "moments": model.activeSession.moments.map(\.title),
            "input": model.input is InboxInput ? "inbox" : "microphone",
            "voice": voice?.name ?? "none",
            "voiceLanguage": voice?.language ?? "",
            "languageVoices": SystemVoice.voices(for: model.settings.recognitionLocale).map { "\($0.name) (\($0.language))" },
            "claudeModel": model.settings.claudeModel,
            "corner": model.settings.corner.rawValue,
        ])
    }
}
