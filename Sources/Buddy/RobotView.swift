import SwiftUI

/// The animated robot. Redraws about 30 times a second while visible and reads the
/// current mouth opening from the avatar state on every frame.
struct RobotView: View {
    @ObservedObject var avatar: AvatarState
    let hue: Double

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: avatar.mode == .hidden)) { timeline in
            RobotFigure(
                t: timeline.date.timeIntervalSinceReferenceDate,
                mode: avatar.mode,
                mouth: avatar.mode == .speaking ? avatar.mouth : 0,
                hue: hue
            )
        }
    }
}

/// Pure drawing of the robot for a given moment in time.
struct RobotFigure: View {
    let t: Double
    let mode: AvatarState.Mode
    let mouth: CGFloat
    let hue: Double

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height / 1.2)
            ZStack {
                shadow(s)
                torso(s)
                head(s)
                    .frame(width: s, height: s * 1.2)
                    .rotationEffect(.degrees(tilt), anchor: UnitPoint(x: 0.5, y: 0.75))
                    .offset(y: bob(s))
                if mode == .thinking {
                    thinkingDots(s)
                }
            }
            .frame(width: s, height: s * 1.2)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
        }
    }

    // MARK: Colors and motion

    private var accent: Color { Color(hue: hue, saturation: 0.75, brightness: 0.95) }
    private var glow: Color { Color(hue: hue, saturation: 0.45, brightness: 1.0) }
    private var screen: Color { Color(red: 0.06, green: 0.08, blue: 0.15) }

    private var antennaColor: Color {
        switch mode {
        case .listening: return Color(hue: 0.36, saturation: 0.8, brightness: 0.95)
        case .thinking: return Color(hue: 0.11, saturation: 0.9, brightness: 1.0)
        case .speaking: return glow
        case .hidden: return Color.gray
        }
    }

    private var pulse: Double { 0.5 + 0.5 * sin(t * (mode == .thinking ? 7 : 3.5)) }

    private var tilt: Double {
        switch mode {
        case .speaking: return sin(t * 3.1) * 2.5
        case .listening: return 4 + sin(t * 1.4) * 1.5 // curious head tilt
        case .thinking: return -3 + sin(t * 2) * 1
        case .hidden: return 0
        }
    }

    private func bob(_ s: CGFloat) -> CGFloat {
        CGFloat(sin(t * 2.2)) * s * 0.012 - mouth * s * 0.02
    }

    private var isBlinking: Bool {
        let cycle = 3.7
        let phase = t.truncatingRemainder(dividingBy: cycle)
        let round = Int(t / cycle)
        return phase < 0.12 || (round % 3 == 0 && phase > 0.25 && phase < 0.37)
    }

    // MARK: Parts

    private func shadow(_ s: CGFloat) -> some View {
        Ellipse()
            .fill(Color.black.opacity(0.18))
            .frame(width: s * 0.55, height: s * 0.07)
            .blur(radius: s * 0.015)
            .position(x: s * 0.5, y: s * 1.15)
    }

    private func torso(_ s: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: s * 0.04)
                .fill(Color(white: 0.7))
                .frame(width: s * 0.14, height: s * 0.07)
                .position(x: s * 0.5, y: s * 0.83)
            RoundedRectangle(cornerRadius: s * 0.12, style: .continuous)
                .fill(LinearGradient(colors: [Color.white, Color(white: 0.82)], startPoint: .top, endPoint: .bottom))
                .frame(width: s * 0.5, height: s * 0.28)
                .shadow(color: Color.black.opacity(0.2), radius: s * 0.02, x: 0, y: s * 0.01)
                .position(x: s * 0.5, y: s * 0.99)
            Circle()
                .fill(accent)
                .frame(width: s * 0.075, height: s * 0.075)
                .shadow(color: glow.opacity(0.9), radius: s * (0.02 + 0.03 * mouth))
                .opacity(0.55 + 0.45 * Double(mouth))
                .position(x: s * 0.5, y: s * 0.97)
        }
    }

    private func head(_ s: CGFloat) -> some View {
        ZStack {
            // Antenna
            Capsule()
                .fill(Color(white: 0.72))
                .frame(width: s * 0.025, height: s * 0.12)
                .position(x: s * 0.5, y: s * 0.14)
            Circle()
                .fill(antennaColor)
                .frame(width: s * 0.08, height: s * 0.08)
                .shadow(color: antennaColor.opacity(0.9), radius: s * 0.025 * (0.5 + pulse))
                .scaleEffect(mode == .hidden ? 1 : 0.9 + 0.15 * pulse)
                .position(x: s * 0.5, y: s * 0.075)

            // Ears
            ForEach([0.085, 0.915], id: \.self) { x in
                RoundedRectangle(cornerRadius: s * 0.03, style: .continuous)
                    .fill(accent.opacity(mode == .listening ? 0.7 + 0.3 * pulse : 0.85))
                    .frame(width: s * 0.07, height: s * 0.2)
                    .position(x: s * CGFloat(x), y: s * 0.48)
            }

            // Head shell and face screen
            RoundedRectangle(cornerRadius: s * 0.2, style: .continuous)
                .fill(LinearGradient(colors: [Color.white, Color(white: 0.85)], startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: s * 0.2, style: .continuous)
                        .stroke(Color.white.opacity(0.8), lineWidth: s * 0.008)
                )
                .frame(width: s * 0.78, height: s * 0.6)
                .shadow(color: Color.black.opacity(0.25), radius: s * 0.03, x: 0, y: s * 0.015)
                .position(x: s * 0.5, y: s * 0.48)
            RoundedRectangle(cornerRadius: s * 0.14, style: .continuous)
                .fill(screen)
                .frame(width: s * 0.64, height: s * 0.44)
                .position(x: s * 0.5, y: s * 0.49)

            eyes(s)
            mouthView(s)

            // Cheeks
            ForEach([0.27, 0.73], id: \.self) { x in
                Circle()
                    .fill(Color(red: 1, green: 0.45, blue: 0.6).opacity(0.35))
                    .frame(width: s * 0.06, height: s * 0.06)
                    .position(x: s * CGFloat(x), y: s * 0.6)
            }
        }
    }

    private func eyes(_ s: CGFloat) -> some View {
        let open: CGFloat
        let dx: CGFloat
        let dy: CGFloat
        switch mode {
        case .thinking:
            open = 0.75
            dx = s * 0.025
            dy = -s * 0.035
        case .listening:
            open = 1.1
            dx = 0
            dy = 0
        default:
            open = 1
            dx = 0
            dy = 0
        }
        let height = s * 0.13 * (isBlinking ? 0.12 : open)
        return ZStack {
            ForEach([0.37, 0.63], id: \.self) { x in
                Capsule()
                    .fill(glow)
                    .frame(width: s * 0.1, height: height)
                    .shadow(color: accent.opacity(0.9), radius: s * 0.025)
                    .position(x: s * CGFloat(x) + dx, y: s * 0.44 + dy)
            }
        }
    }

    @ViewBuilder
    private func mouthView(_ s: CGFloat) -> some View {
        if mode == .speaking && mouth > 0.04 {
            RoundedRectangle(cornerRadius: s * 0.045, style: .continuous)
                .fill(glow)
                .frame(width: s * (0.15 + 0.06 * mouth), height: s * (0.03 + 0.12 * mouth))
                .shadow(color: accent.opacity(0.8), radius: s * 0.02)
                .position(x: s * 0.5, y: s * 0.6)
        } else if mode == .thinking {
            Capsule()
                .fill(glow)
                .frame(width: s * 0.08, height: s * 0.022)
                .position(x: s * 0.52, y: s * 0.6)
        } else {
            Smile()
                .stroke(glow, style: StrokeStyle(lineWidth: s * 0.022, lineCap: .round))
                .frame(width: s * 0.16, height: s * 0.045)
                .shadow(color: accent.opacity(0.8), radius: s * 0.015)
                .position(x: s * 0.5, y: s * 0.59)
        }
    }

    private func thinkingDots(_ s: CGFloat) -> some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.white)
                    .frame(width: s * 0.06, height: s * 0.06)
                    .shadow(color: Color.black.opacity(0.25), radius: s * 0.01)
                    .offset(y: -CGFloat(max(0, sin(t * 6 - Double(i) * 0.7))) * s * 0.04)
                    .position(x: s * (0.74 + 0.08 * CGFloat(i)), y: s * 0.1)
            }
        }
    }
}

struct Smile: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.midX, y: rect.maxY * 1.8)
        )
        return path
    }
}
