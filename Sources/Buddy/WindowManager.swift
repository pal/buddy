import AppKit
import SwiftUI

/// Opens the app's regular windows. A menu bar app has no Dock icon, so windows are
/// brought to the front explicitly.
@MainActor
final class WindowManager {
    private let model: AppModel
    private var windows: [String: NSWindow] = [:]
    private var settings: SettingsWindowController?

    init(model: AppModel) {
        self.model = model
        model.showSettingsWindow = { [weak self] in self?.showSettings() }
        model.testEditShortcuts = { [weak self] in self?.settingsController().testEditShortcuts() }
    }

    func showEditor() {
        show(id: "editor", title: "Buddy – presentationer",
             size: NSSize(width: 1020, height: 720), minSize: NSSize(width: 760, height: 520)) {
            SessionEditorView(model: model, store: model.store)
        }
    }

    func showSettings() {
        let tab = model.settingsTab
        settingsController().show(tab)
    }

    private func settingsController() -> SettingsWindowController {
        if let settings { return settings }
        let controller = SettingsWindowController(model: model)
        settings = controller
        return controller
    }

    func showControlPanel() {
        show(id: "control", title: "Buddy – kontrollpanel",
             size: NSSize(width: 640, height: 640), minSize: NSSize(width: 480, height: 420)) {
            ControlPanelView(model: model, live: model.live)
        }
    }

    private func show<Content: View>(id: String, title: String, size: NSSize, minSize: NSSize, content: () -> Content) {
        if let window = windows[id] {
            fitOnScreen(window, minSize: minSize)
            bringToFront(window)
            record(id, window)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: content())
        // The window decides its size and the content adapts (and scrolls). Otherwise the
        // content's own size can stretch the window far beyond the screen.
        host.sizingOptions = []
        window.contentView = host
        window.minSize = minSize
        // Opens on the current space, also over a presentation in full screen.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.center()
        window.setFrameAutosaveName("Buddy.window.\(id)")
        fitOnScreen(window, minSize: minSize)
        windows[id] = window
        bringToFront(window)
        record(id, window)
    }

    private func bringToFront(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Keeps a window, also one restored from a saved frame, inside the visible screen area.
    private func fitOnScreen(_ window: NSWindow, minSize: NSSize) {
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        var frame = window.frame
        frame.size.width = min(max(frame.width, minSize.width), visible.width)
        frame.size.height = min(max(frame.height, minSize.height), visible.height)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        if frame != window.frame {
            window.setFrame(frame, display: false)
        }
    }

    private func record(_ id: String, _ window: NSWindow) {
        guard EventLog.shared.isEnabled else { return }
        let screen = window.screen ?? NSScreen.main
        EventLog.shared.record("window", [
            "id": id,
            "frame": EventLog.frame(window.frame),
            "visible": EventLog.frame(screen?.visibleFrame ?? .zero),
            "screen": EventLog.frame(screen?.frame ?? .zero),
            "number": window.windowNumber,
            "isVisible": window.isVisible,
            "onActiveSpace": window.isOnActiveSpace,
        ])
    }
}
