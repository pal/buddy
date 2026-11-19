import AppKit

@main
enum BuddyApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Menu bar app: no Dock icon, no main menu.
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel()
        let windows = WindowManager(model: model)
        self.model = model
        self.windows = windows
        overlay = OverlayController(avatar: model.avatar, settings: model.settings)
        statusBar = StatusBarController(model: model, windows: windows)

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

    func applicationWillTerminate(_ notification: Notification) {
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
