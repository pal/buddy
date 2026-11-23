import AppKit

/// The app's main menu. A menu bar app shows no menu bar, but AppKit still uses these menus
/// for the keyboard shortcuts in Buddy's windows: ⌘X, ⌘C, ⌘V, ⌘A and ⌘Z in text fields
/// (pasting an API key), ⌘W to close a window, ⌘, for the settings and ⌘Q to quit.
@MainActor
final class MainMenu: NSObject {
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    func install() {
        let main = NSMenu()

        let app = NSMenu(title: "Buddy")
        app.addItem(withTitle: "Om Buddy", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Inställningar…", action: #selector(showSettings), keyEquivalent: ",").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Avsluta Buddy", action: #selector(quit), keyEquivalent: "q").target = self
        add(app, to: main)

        let edit = NSMenu(title: "Redigera")
        edit.addItem(withTitle: "Ångra", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Gör om", action: Selector(("redo:")), keyEquivalent: "z").keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Klipp ut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Kopiera", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Klistra in", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Markera alla", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        add(edit, to: main)

        let window = NSMenu(title: "Fönster")
        window.addItem(withTitle: "Stäng", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimera", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        add(window, to: main)
        NSApp.windowsMenu = window

        NSApp.mainMenu = main
    }

    private func add(_ menu: NSMenu, to main: NSMenu) {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        main.addItem(item)
    }

    @objc private func showSettings() {
        model.showSettingsWindow?()
    }

    @objc private func quit() {
        model.quit()
    }
}
