import AppKit
import SwiftUI

/// Opens the app's regular windows. A menu bar app has no Dock icon, so windows are
/// brought to the front explicitly.
@MainActor
final class WindowManager {
    private let model: AppModel
    private var windows: [String: NSWindow] = [:]

    init(model: AppModel) {
        self.model = model
    }

    func showEditor() {
        show(id: "editor", title: "Buddy – presentationer", size: NSSize(width: 1020, height: 720)) {
            SessionEditorView(model: model, store: model.store)
        }
    }

    func showSettings() {
        show(id: "settings", title: "Buddy – inställningar", size: NSSize(width: 620, height: 560)) {
            SettingsView(model: model, settings: model.settings)
        }
    }

    func showControlPanel() {
        show(id: "control", title: "Buddy – kontrollpanel", size: NSSize(width: 640, height: 640)) {
            ControlPanelView(model: model, live: model.live)
        }
    }

    private func show<Content: View>(id: String, title: String, size: NSSize, content: () -> Content) {
        if let window = windows[id] {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
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
        window.contentView = NSHostingView(rootView: content())
        window.minSize = NSSize(width: 480, height: 360)
        window.center()
        window.setFrameAutosaveName("Buddy.\(id)")
        windows[id] = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
