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
        model.reportStatusMenu = { [weak self] in
            guard let self else { return }
            self.refresh()
            EventLog.shared.record("statusMenu", [
                "items": self.item.menu?.items.map(\.title) ?? [],
                "toolTips": self.item.menu?.items.compactMap(\.toolTip) ?? [],
            ])
        }
        model.objectWillChange
            .merge(with: model.store.objectWillChange, model.updater.objectWillChange)
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

    /// Crossed out: Buddy is not listening and does not use the microphone.
    static let notListeningSymbol = NSImage(systemSymbolName: "ear.slash", accessibilityDescription: nil) != nil
        ? "ear.slash" : "mic.slash"

    private var shownSymbol: String?

    private func updateIcon() {
        let symbol: String
        switch model.phase {
        case .paused: symbol = StatusBarController.notListeningSymbol
        case .listening: symbol = "ear"
        case .triggered, .awaitingReply: symbol = "ear.badge.waveform"
        case .thinking: symbol = "ellipsis.bubble"
        case .speaking, .closing: symbol = "bubble.left.fill"
        }
        let description = "Buddy – \(statusText)"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
            ?? NSImage(systemSymbolName: "face.smiling", accessibilityDescription: description)
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = model.phase == .paused
            ? "Buddy lyssnar inte och använder inte mikrofonen"
            : description
        if symbol != shownSymbol {
            shownSymbol = symbol
            recordIcon(symbol, image)
        }
    }

    /// For the end-to-end tests: which icon is shown, and a picture of it.
    private func recordIcon(_ symbol: String, _ image: NSImage?) {
        guard EventLog.shared.isEnabled else { return }
        EventLog.shared.record("statusIcon", ["symbol": symbol, "listening": model.listening, "phase": model.phase.rawValue])
        guard let image, let folder = LaunchOptions.current.dataDirectory else { return }
        let size = NSSize(width: 64, height: 64)
        let picture = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            image.draw(in: rect.insetBy(dx: 8, dy: 8))
            return true
        }
        if let tiff = picture.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? png.write(to: folder.appendingPathComponent("status-icon-\(symbol).png"))
        }
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
        if model.settings.voiceProvider == .elevenLabs, let voiceProblem = model.voiceProblem {
            let voiceItem = add(menu, "⚠︎ ElevenLabs fungerar inte, Buddy pratar med macOS-rösten…", #selector(showVoiceSettings))
            voiceItem.toolTip = voiceProblem
        }
        menu.addItem(.separator())

        let listen = add(menu, "Lyssna efter triggerfraser", #selector(toggleListening), key: "l")
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
        add(menu, model.updater.readyToInstall ? "Installera ny version och starta om" : "Sök efter uppdateringar…",
            #selector(checkForUpdates))
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Avsluta Buddy", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
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
    @objc private func showVoiceSettings() {
        model.settingsTab = .voice
        windows.showSettings()
    }
    @objc private func showControlPanel() { windows.showControlPanel() }
    @objc private func quit() { model.quit() }

    @objc private func checkForUpdates() {
        if model.updater.readyToInstall {
            model.updater.install(relaunch: true)
            return
        }
        model.settingsTab = .updates
        windows.showSettings()
        Task { @MainActor in await model.updater.check() }
    }

    @objc private func selectSession(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = UUID(uuidString: raw) else { return }
        model.activate(id)
    }

    @objc private func queueMoment(_ sender: NSMenuItem) {
        let id = (sender.representedObject as? String).flatMap(UUID.init(uuidString:))
        model.queueMoment(id)
    }
}
