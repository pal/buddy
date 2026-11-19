// A stand-in for Keynote/PowerPoint: one slide in native full screen.
// Build: swiftc -parse-as-library e2e/tools/PresentationStub.swift -o PresentationStub
// Run with --windowed to skip full screen.
import AppKit

/// Background color of the slide. The e2e driver looks for it in screenshots.
let slideColor = NSColor(srgbRed: 20.0 / 255, green: 41.0 / 255, blue: 110.0 / 255, alpha: 1)

final class SlideView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        slideColor.setFill()
        bounds.fill()
        let title = "AI på jobbet" as NSString
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 64),
            .foregroundColor: NSColor.white,
        ]
        let titleSize = title.size(withAttributes: titleAttributes)
        title.draw(
            at: NSPoint(x: bounds.midX - titleSize.width / 2, y: bounds.height * 0.62),
            withAttributes: titleAttributes
        )
        let subtitle = "Bild 3 av 12 – testpresentation för Buddy" as NSString
        let subtitleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 28),
            .foregroundColor: NSColor(white: 0.85, alpha: 1),
        ]
        let subtitleSize = subtitle.size(withAttributes: subtitleAttributes)
        subtitle.draw(
            at: NSPoint(x: bounds.midX - subtitleSize.width / 2, y: bounds.height * 0.62 - 60),
            withAttributes: subtitleAttributes
        )
    }
}

final class StubDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let frame = NSScreen.screens.first?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Presentation"
        window.contentView = SlideView(frame: frame)
        window.collectionBehavior = [.fullScreenPrimary]
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        if !CommandLine.arguments.contains("--windowed") {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                window.toggleFullScreen(nil)
            }
        }
    }
}

@main
enum PresentationStub {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = StubDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
