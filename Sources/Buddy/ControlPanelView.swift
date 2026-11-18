import SwiftUI
import BuddyCore

/// Live view of what Buddy hears and does, with manual controls and typed "speech" for rehearsals.
struct ControlPanelView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var live: LiveState
    @State private var typed = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 12, height: 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Buddy \(model.phase.label)").font(.headline)
                    Text(subtitle).font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Toggle("Lyssna", isOn: Binding(
                    get: { model.listening },
                    set: { on in
                        Task { @MainActor in
                            await model.setListening(on)
                        }
                    }
                ))
                .toggleStyle(.switch)
            }

            if let problem = model.problem {
                Text(problem)
                    .font(.callout)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Mikrofon").font(.caption).foregroundColor(.secondary)
                    ProgressView(value: Double(min(1, live.micLevel * 8)))
                        .progressViewStyle(.linear)
                }
                Text("Hör just nu").font(.caption).foregroundColor(.secondary)
                Text(live.transcript.isEmpty ? "–" : live.transcript)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
            }

            HStack {
                Button(model.phase.isActive ? "Avsluta dialogen" : "Starta nästa moment") {
                    model.toggleMoment()
                }
                Button("Tyst!") {
                    model.interrupt()
                }
                .disabled(!model.phase.isActive)
                Button("Testa avataren") {
                    model.testAvatar()
                }
                .disabled(model.phase.isActive)
                Spacer()
                Button("Nollställ moment") {
                    model.resetProgress()
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Repetera utan mikrofon").font(.caption).foregroundColor(.secondary)
                HStack {
                    TextField("Skriv det du skulle säga, t.ex. ”Vad tycker du, Buddy?”", text: $typed)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(sendTyped)
                    Button("Skicka", action: sendTyped)
                        .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Text("Logg").font(.headline)
            ScrollViewReader { proxy in
                List(live.log) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Text(entry.time.formatted(date: .omitted, time: .standard))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                        Text(entry.text)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .id(entry.id)
                }
                .onChange(of: live.log.count) { _ in
                    if let last = live.log.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .padding(16)
    }

    private var subtitle: String {
        if let moment = model.activeMoment {
            return "Moment: \(moment.title)"
        }
        return "Presentation: \(model.activeSession.name)"
    }

    private var statusColor: Color {
        switch model.phase {
        case .paused: return .gray
        case .listening: return .green
        case .triggered, .awaitingReply: return .blue
        case .thinking: return .orange
        case .speaking, .closing: return .purple
        }
    }

    private func sendTyped() {
        model.simulate(typed)
        typed = ""
    }
}
