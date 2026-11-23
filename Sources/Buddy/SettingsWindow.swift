import AppKit
import SwiftUI
import BuddyCore

/// The settings window, built like the settings of macOS's own apps: a toolbar with one
/// button per pane, the pane's name as the window title, a window that cannot be resized or
/// zoomed and always fits the pane, and the last pane shown again next time.
@MainActor
final class SettingsWindowController: NSWindowController {
    private let model: AppModel
    private let panes: SettingsTabViewController
    /// Centred the first time it opens, unless it has a saved position.
    private var centerWhenShown: Bool

    init(model: AppModel) {
        self.model = model
        panes = SettingsTabViewController(model: model)
        let window = NSWindow(contentViewController: panes)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        // Opens on the current space, also over a presentation in full screen.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        let autosaveName = "Buddy.settings"
        centerWhenShown = UserDefaults.standard.string(forKey: "NSWindow Frame \(autosaveName)") == nil
        window.setFrameAutosaveName(autosaveName)
        super.init(window: window)
        panes.onLayout = { [weak self] in self?.record() }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func show(_ tab: SettingsTab) {
        guard let window else { return }
        panes.select(tab)
        panes.fitWindow(animated: false)
        if centerWhenShown {
            window.center()
            centerWhenShown = false
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        panes.fitWindow(animated: false)
        panes.clearFocus()
    }

    // MARK: End-to-end tests

    /// Presses ⌘A and ⌘V in the Anthropic key field, first without and then with the main
    /// menu, and then ⌘W, as key events sent through the app like real ones, and records what
    /// happened. The field and the pasteboard get their old contents back.
    func testEditShortcuts() {
        model.voicePickerOpen = false
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            show(.ai)
            let settings = model.settings
            let original = settings.anthropicKey
            let pasted = "sk-ant-e2e-pasted"
            let pasteboard = NSPasteboard.general
            let previous = pasteboard.string(forType: .string)
            pasteboard.clearContents()
            pasteboard.setString(pasted, forType: .string)
            let menu = NSApp.mainMenu

            try? await Task.sleep(nanoseconds: 700_000_000)
            let fieldFound = window.flatMap { SettingsWindowController.secureField(in: $0.contentView) } != nil
            NSApp.mainMenu = nil
            let withoutMenu = await pasteIntoKeyField(pasted, restoring: original)
            NSApp.mainMenu = menu
            let withMenu = await pasteIntoKeyField(pasted, restoring: original)
            sendCommand("w", keyCode: 13)
            try? await Task.sleep(nanoseconds: 500_000_000)
            pasteboard.clearContents()
            if let previous {
                pasteboard.setString(previous, forType: .string)
            }
            EventLog.shared.record("editShortcuts", [
                "fieldFound": fieldFound,
                "pasteWithoutMainMenu": withoutMenu.field,
                "pasteIntoField": withMenu.field,
                "pasteIntoSetting": withMenu.setting,
                "closedWithCommandW": !(window?.isVisible ?? true),
                "keyRestored": settings.anthropicKey == original,
            ])
        }
    }

    /// Focuses the key field, presses ⌘A and ⌘V, and reports whether the pasted text reached the
    /// field and the setting. Then puts the old key back.
    private func pasteIntoKeyField(_ pasted: String, restoring original: String) async -> (field: Bool, setting: Bool) {
        guard let window, let field = SettingsWindowController.secureField(in: window.contentView) else {
            return (false, false)
        }
        _ = window.makeFirstResponder(field)
        try? await Task.sleep(nanoseconds: 300_000_000)
        sendCommand("a", keyCode: 0)
        sendCommand("v", keyCode: 9)
        try? await Task.sleep(nanoseconds: 500_000_000)
        let result = (field: field.stringValue == pasted, setting: model.settings.anthropicKey == pasted)
        model.settings.anthropicKey = original
        try? await Task.sleep(nanoseconds: 300_000_000)
        return result
    }

    private func sendCommand(_ character: String, keyCode: UInt16) {
        guard let window,
              let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: character, charactersIgnoringModifiers: character,
                isARepeat: false, keyCode: keyCode)
        else { return }
        NSApp.sendEvent(event)
    }

    private static func secureField(in view: NSView?) -> NSSecureTextField? {
        guard let view else { return nil }
        if let field = view as? NSSecureTextField { return field }
        for subview in view.subviews {
            if let field = secureField(in: subview) { return field }
        }
        return nil
    }

    private func record() {
        guard EventLog.shared.isEnabled, let window else { return }
        let content = window.contentView?.frame.size ?? .zero
        let pane = panes.selectedPane?.preferredContentSize ?? .zero
        let screen = window.screen ?? NSScreen.main
        EventLog.shared.record("settingsWindow", [
            "tab": panes.selectedTab?.rawValue ?? "",
            "title": window.title,
            "toolbar": (window.toolbar?.items ?? []).map(\.label).filter { !$0.isEmpty },
            "toolbarStyle": window.toolbarStyle == .preference ? "preference" : "other",
            "resizable": window.styleMask.contains(.resizable),
            "miniaturizable": window.styleMask.contains(.miniaturizable),
            "zoomEnabled": window.standardWindowButton(.zoomButton)?.isEnabled ?? false,
            "content": ["w": Double(content.width), "h": Double(content.height)],
            "pane": ["w": Double(pane.width), "h": Double(pane.height)],
            "frame": EventLog.frame(window.frame),
            "visible": EventLog.frame(screen?.visibleFrame ?? .zero),
            "isVisible": window.isVisible,
            "onActiveSpace": window.isOnActiveSpace,
            "editingText": window.firstResponder is NSText,
        ])
    }
}

/// One pane per settings tab, switched from the window's toolbar. The window is resized to
/// fit each pane, also when a pane grows or shrinks (for example when ElevenLabs is chosen).
@MainActor
final class SettingsTabViewController: NSTabViewController {
    private let model: AppModel
    var onLayout: (() -> Void)?

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        transitionOptions = [.allowUserInteraction]
        for tab in SettingsTab.allCases {
            let host = NSHostingController(rootView: SettingsPane(tab: tab, model: model, settings: model.settings))
            // The pane reports the size it needs; the window follows it.
            host.sizingOptions = [.preferredContentSize]
            host.title = tab.title
            let item = NSTabViewItem(viewController: host)
            item.label = tab.title
            item.identifier = tab.rawValue
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            addTabViewItem(item)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    var selectedTab: SettingsTab? {
        guard tabViewItems.indices.contains(selectedTabViewItemIndex),
              let identifier = tabViewItems[selectedTabViewItemIndex].identifier as? String
        else { return nil }
        return SettingsTab(rawValue: identifier)
    }

    var selectedPane: NSViewController? {
        tabViewItems.indices.contains(selectedTabViewItemIndex) ? tabViewItems[selectedTabViewItemIndex].viewController : nil
    }

    func select(_ tab: SettingsTab) {
        guard let index = SettingsTab.allCases.firstIndex(of: tab), selectedTabViewItemIndex != index else { return }
        selectedTabViewItemIndex = index
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        let visible = view.window?.isVisible ?? false
        // Only a pane chosen in the open window is remembered, not the first pane that
        // AppKit selects while the window is being built.
        if visible, let tab = selectedTab, model.settingsTab != tab {
            model.settingsTab = tab
        }
        fitWindow(animated: visible)
        clearFocus()
    }

    /// A pane opens without a selected text field, so a key press cannot overwrite an API key.
    /// AppKit selects the first field once the window is shown, so this runs right after.
    func clearFocus() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.view.window else { return }
            if window.firstResponder is NSText {
                _ = window.makeFirstResponder(nil)
            }
            self.onLayout?()
        }
    }

    override func preferredContentSizeDidChange(for viewController: NSViewController) {
        super.preferredContentSizeDidChange(for: viewController)
        guard viewController === selectedPane else { return }
        fitWindow(animated: view.window?.isVisible ?? false)
    }

    /// Sizes the window to the selected pane, keeping its top edge in place and the whole
    /// window on the screen.
    func fitWindow(animated: Bool) {
        guard let window = view.window, let pane = selectedPane else { return }
        var size = pane.preferredContentSize
        if size.width < 1 || size.height < 1 {
            size = pane.view.fittingSize
        }
        guard size.width >= 1, size.height >= 1 else { return }
        let chrome = window.frame.height - (window.contentView?.frame.height ?? window.frame.height)
        var frame = window.frame
        frame.size = NSSize(width: size.width, height: size.height + chrome)
        frame.origin.y = window.frame.maxY - frame.height
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            frame.size.height = min(frame.height, visible.height)
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        }
        if frame != window.frame {
            window.setFrame(frame, display: true, animate: animated)
        }
        onLayout?()
    }
}
