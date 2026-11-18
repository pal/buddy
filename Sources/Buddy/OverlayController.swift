import AppKit
import Combine
import SwiftUI

/// Transparent, click-through panel that floats above full-screen presentations.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Places one overlay panel per chosen screen, in the chosen corner.
@MainActor
final class OverlayController {
    private let avatar: AvatarState
    private let settings: AppSettings
    private var panels: [OverlayPanel] = []
    private var layoutSignature = ""
    private var cancellables: Set<AnyCancellable> = []
    private var screenObserver: NSObjectProtocol?

    init(avatar: AvatarState, settings: AppSettings) {
        self.avatar = avatar
        self.settings = settings
        rebuild()
        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildIfLayoutChanged()
            }
            .store(in: &cancellables)
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            let target = self
            Task { @MainActor in target?.rebuild() }
        }
    }

    private var currentSignature: String {
        let screens = NSScreen.screens.map { NSStringFromRect($0.frame) }.joined(separator: ";")
        return "\(settings.corner.rawValue)|\(settings.screen.rawValue)|\(Int(settings.avatarSize))|\(screens)"
    }

    private func rebuildIfLayoutChanged() {
        if currentSignature != layoutSignature {
            rebuild()
        }
    }

    func rebuild() {
        layoutSignature = currentSignature
        for panel in panels {
            panel.orderOut(nil)
        }
        panels = targetScreens().map(makePanel)
    }

    private func targetScreens() -> [NSScreen] {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return [] }
        switch settings.screen {
        case .main:
            return [primary]
        case .external:
            return [screens.first(where: { $0 != primary }) ?? primary]
        case .all:
            return screens
        }
    }

    private func makePanel(on screen: NSScreen) -> OverlayPanel {
        let size = CGFloat(settings.avatarSize)
        let width = size * 3.4
        let height = size * 1.55
        let margin: CGFloat = 28
        let frame = screen.frame
        let corner = settings.corner
        let x = corner.isRight ? frame.maxX - width - margin : frame.minX + margin
        let y = corner.isBottom ? frame.minY + margin : frame.maxY - height - margin

        let panel = OverlayPanel(
            contentRect: NSRect(x: x, y: y, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false

        let host = NSHostingView(rootView: OverlayView(avatar: avatar, settings: settings))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = host
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        panel.orderFrontRegardless()
        return panel
    }
}

/// Robot plus subtitle bubble, anchored in the panel's corner.
struct OverlayView: View {
    @ObservedObject var avatar: AvatarState
    @ObservedObject var settings: AppSettings

    var body: some View {
        let corner = settings.corner
        let size = CGFloat(settings.avatarSize)
        let visible = avatar.mode != .hidden
        HStack(alignment: corner.isBottom ? .bottom : .top, spacing: size * 0.06) {
            if corner.isRight {
                bubble(size: size, corner: corner)
                robot(size: size)
            } else {
                robot(size: size)
                bubble(size: size, corner: corner)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment(corner))
        .scaleEffect(visible ? 1 : 0.25, anchor: anchor(corner))
        .opacity(visible ? 1 : 0)
        .animation(.spring(response: 0.45, dampingFraction: 0.7), value: visible)
    }

    private func robot(size: CGFloat) -> some View {
        RobotView(avatar: avatar, hue: settings.robotHue)
            .frame(width: size, height: size * 1.2)
    }

    @ViewBuilder
    private func bubble(size: CGFloat, corner: OverlayCorner) -> some View {
        if settings.showSubtitles, avatar.mode == .speaking, let text = avatar.subtitle {
            Text(text)
                .font(.system(size: max(14, size * 0.095), weight: .semibold, design: .rounded))
                .foregroundColor(Color(white: 0.1))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, size * 0.09)
                .padding(.vertical, size * 0.06)
                .background(
                    RoundedRectangle(cornerRadius: size * 0.1, style: .continuous)
                        .fill(Color.white.opacity(0.95))
                        .shadow(color: Color.black.opacity(0.25), radius: 8, x: 0, y: 3)
                )
                .frame(maxWidth: size * 2.2, alignment: corner.isRight ? .trailing : .leading)
                .padding(corner.isBottom ? .bottom : .top, size * 0.6)
                .id(text)
                .transition(.opacity)
        }
    }

    private func alignment(_ corner: OverlayCorner) -> Alignment {
        switch corner {
        case .bottomRight: return .bottomTrailing
        case .bottomLeft: return .bottomLeading
        case .topRight: return .topTrailing
        case .topLeft: return .topLeading
        }
    }

    private func anchor(_ corner: OverlayCorner) -> UnitPoint {
        switch corner {
        case .bottomRight: return .bottomTrailing
        case .bottomLeft: return .bottomLeading
        case .topRight: return .topTrailing
        case .topLeft: return .topLeading
        }
    }
}
