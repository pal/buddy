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
        hotKeys.register(key: .b) { model.toggleMoment() }
        hotKeys.register(key: .period) { model.interrupt() }
        hotKeys.register(key: .l) { model.toggleListening() }
        self.hotKeys = hotKeys

        model.launch()
        if model.settings.isFirstLaunch {
            model.settings.isFirstLaunch = false
            windows.showEditor()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.shutdown()
    }
}
