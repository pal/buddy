import AppKit
import Combine
import BuddyCore

/// The menu bar icon and its menu.
@MainActor
final class StatusBarController: NSObject {
    private let model: AppModel
    private let windows: WindowManager
    private let item: NSStatusItem
    private var cancellables: Set<AnyCancellable> = []

    init(model: AppModel, windows: WindowManager) {
        self.model = model
        self.windows = windows
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        refresh()
        EventLog.shared.record("statusItem", [
            "visible": item.isVisible,
            "hasIcon": item.button?.image != nil,
            "menuItems": item.menu?.items.map(\.title) ?? [],
        ])
        model.objectWillChange
            .merge(with: model.store.objectWillChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)
    }

    private func refresh() {
        updateIcon()
        item.menu = buildMenu()
    }

    private func updateIcon() {
        let symbol: String
        switch model.phase {
        case .paused: symbol = "moon.zzz"
        case .listening: symbol = "ear"
        case .triggered, .awaitingReply: symbol = "ear.badge.waveform"
        case .thinking: symbol = "ellipsis.bubble"
        case .speaking, .closing: symbol = "bubble.left.fill"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Buddy")
            ?? NSImage(systemSymbolName: "face.smiling", accessibilityDescription: "Buddy")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "Buddy – \(statusText)"
    }

    private var statusText: String { model.phase.label }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        var header = "Buddy – \(statusText)"
        if let moment = model.activeMoment {
            header += " (\(moment.title))"
        }
        let headerItem = NSMenuItem(title: header, action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        if let problem = model.problem {
            let problemItem = NSMenuItem(title: "⚠︎ " + problem, action: nil, keyEquivalent: "")
            problemItem.isEnabled = false
            menu.addItem(problemItem)
        }
        menu.addItem(.separator())

        let listen = add(menu, "Lyssna efter triggers", #selector(toggleListening), key: "l")
        listen.state = model.listening ? .on : .off

        let active = model.phase.isActive
        add(menu, active ? "Avsluta dialogen" : "Starta nästa moment nu", #selector(toggleMoment), key: "b")
        let hush = add(menu, "Tyst! (avbryt repliken)", #selector(interrupt), key: ".")
        hush.isEnabled = active
        menu.addItem(.separator())

        menu.addItem(sessionsItem())
        menu.addItem(momentsItem())
        menu.addItem(.separator())

        add(menu, "Testa avataren", #selector(testAvatar)).isEnabled = !active
        add(menu, "Förbered repliker (ljud i förväg)", #selector(prepareLines))
        add(menu, "Kontrollpanel…", #selector(showControlPanel))
        add(menu, "Redigera presentationer…", #selector(showEditor))
        add(menu, "Inställningar…", #selector(showSettings))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Avsluta Buddy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        return menu
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String? = nil) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key ?? "")
        menuItem.target = self
        if key != nil {
            menuItem.keyEquivalentModifierMask = [.control, .option, .command]
        }
        menu.addItem(menuItem)
        return menuItem
    }

    private func sessionsItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Presentation: \(model.activeSession.name)", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for session in model.store.sessions {
            let entry = NSMenuItem(title: session.name, action: #selector(selectSession(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = session.id.uuidString
            entry.state = session.id == model.activeSession.id ? .on : .off
            submenu.addItem(entry)
        }
        submenu.addItem(.separator())
        let edit = NSMenuItem(title: "Redigera presentationer…", action: #selector(showEditor), keyEquivalent: "")
        edit.target = self
        submenu.addItem(edit)
        parent.submenu = submenu
        return parent
    }

    private func momentsItem() -> NSMenuItem {
        let session = model.activeSession
        let parent = NSMenuItem(title: "Nästa moment", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let automatic = NSMenuItem(title: "Automatiskt (nästa i ordning)", action: #selector(queueMoment(_:)), keyEquivalent: "")
        automatic.target = self
        automatic.state = model.queuedMomentID == nil ? .on : .off
        submenu.addItem(automatic)
        submenu.addItem(.separator())
        for moment in session.moments {
            let done = model.isCompleted(moment)
            var title = (done ? "✓ " : "    ") + moment.title
            if !moment.enabled { title += " (avstängt)" }
            let entry = NSMenuItem(title: title, action: #selector(queueMoment(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = moment.id.uuidString
            entry.state = model.queuedMomentID == moment.id ? .on : .off
            entry.isEnabled = moment.enabled
            submenu.addItem(entry)
        }
        submenu.addItem(.separator())
        let reset = NSMenuItem(title: "Börja om (nollställ alla moment)", action: #selector(resetProgress), keyEquivalent: "")
        reset.target = self
        submenu.addItem(reset)
        parent.submenu = submenu
        return parent
    }

    // MARK: Actions

    @objc private func toggleListening() { model.toggleListening() }
    @objc private func toggleMoment() { model.toggleMoment() }
    @objc private func interrupt() { model.interrupt() }
    @objc private func testAvatar() { model.testAvatar() }
    @objc private func prepareLines() { model.prepareLines() }
    @objc private func resetProgress() { model.resetProgress() }
    @objc private func showEditor() { windows.showEditor() }
    @objc private func showSettings() { windows.showSettings() }
    @objc private func showControlPanel() { windows.showControlPanel() }

    @objc private func selectSession(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = UUID(uuidString: raw) else { return }
        model.activate(id)
    }

    @objc private func queueMoment(_ sender: NSMenuItem) {
        let id = (sender.representedObject as? String).flatMap(UUID.init(uuidString:))
        model.queueMoment(id)
    }
}
