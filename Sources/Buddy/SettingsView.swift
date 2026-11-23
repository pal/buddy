import AVFoundation
import SwiftUI
import BuddyCore

enum SettingsTab: String, CaseIterable, Identifiable {
    case voice, ai, listening, avatar, shortcuts, updates

    var id: String { rawValue }
    var title: String {
        switch self {
        case .voice: return "Röst"
        case .ai: return "AI"
        case .listening: return "Lyssna"
        case .avatar: return "Avatar"
        case .shortcuts: return "Kortkommandon"
        case .updates: return "Uppdateringar"
        }
    }
    /// SF Symbol for the pane's toolbar button.
    var symbol: String {
        switch self {
        case .voice: return "speaker.wave.2"
        case .ai: return "sparkles"
        case .listening: return "mic"
        case .avatar: return "face.smiling"
        case .shortcuts: return "keyboard"
        case .updates: return "arrow.down.circle"
        }
    }
}

/// One pane of the settings window, laid out like the settings of macOS's own apps: labels on
/// the left, right-aligned and ending with a colon, controls on the right, explanations in
/// small grey text under the controls. The pane is as tall as its content; the window fits it.
struct SettingsPane: View {
    let tab: SettingsTab
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings

    static let width: CGFloat = 600
    static let margin: CGFloat = 32

    var body: some View {
        content
            .formStyle(.columns)
            .background(GeometryReader { proxy in
                Color.clear
                    .onAppear { Self.record(tab, proxy.size) }
                    .onChange(of: proxy.size) { Self.record(tab, $0) }
            })
            .padding(.horizontal, Self.margin)
            .padding(.vertical, 24)
            .frame(width: Self.width)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// For the end-to-end tests: the width the pane's content takes, which must fit the window.
    @MainActor private static func record(_ tab: SettingsTab, _ size: CGSize) {
        guard EventLog.shared.isEnabled else { return }
        EventLog.shared.record("settingsPaneLayout", [
            "tab": tab.rawValue,
            "width": Double(size.width),
            "available": Double(width - 2 * margin),
        ])
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .voice: VoicePane(model: model, settings: settings)
        case .ai: AIPane(model: model, settings: settings)
        case .listening: ListeningPane(settings: settings)
        case .avatar: AvatarPane(model: model, settings: settings)
        case .shortcuts: ShortcutsPane()
        case .updates: UpdatesPane(updater: model.updater, settings: settings)
        }
    }
}

/// Small grey explanation under the controls.
private struct Note: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A slider with its current value after it.
private struct ValueSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            if let step {
                Slider(value: $value, in: range, step: step)
            } else {
                Slider(value: $value, in: range)
            }
            Text(text)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
        }
    }
}

/// A slider with words for its two ends under it, as in System Settings. The slider comes
/// first, so the form lines it up with the other controls.
private struct RangeSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let low: String
    let high: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Slider(value: $value, in: range)
            HStack {
                Text(low)
                Spacer()
                Text(high)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }
}

private func seconds(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(1))) + " s"
}

/// A control with its explanation under it. Both sit in the form's control column, so the
/// explanation wraps at the column's width.
private struct Explained<Content: View>: View {
    let note: String
    let content: Content

    init(_ note: String, @ViewBuilder content: () -> Content) {
        self.note = note
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            content
            Note(note)
        }
    }
}

private struct VoicePane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings

    private var keyMissing: Bool {
        settings.elevenLabsKey.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var voiceLabel: String {
        if !settings.elevenLabsVoiceName.isEmpty { return settings.elevenLabsVoiceName }
        return settings.elevenLabsVoiceID.isEmpty ? "Ingen vald" : settings.elevenLabsVoiceID
    }

    var body: some View {
        Form {
            LabeledContent("Talsyntes:") {
                VStack(alignment: .leading, spacing: 5) {
                    Picker("Talsyntes", selection: $settings.voiceProvider) {
                        ForEach(VoiceProvider.allCases) { provider in
                            Text(provider.label).tag(provider)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    if settings.voiceProvider == .elevenLabs {
                        Note("Om ElevenLabs inte svarar används macOS-rösten.")
                    }
                }
            }

            if settings.voiceProvider == .system {
                LabeledContent("Röst:") {
                    Explained("Fler och bättre röster finns i Systeminställningar → Hjälpmedel → Uppläst innehåll → Systemröst → Hantera röster. Ladda ner en svensk röst i premium- eller förbättrad kvalitet.") {
                        Picker("Röst", selection: $settings.systemVoiceID) {
                            Text("Bästa tillgängliga för språket").tag("")
                            ForEach(SystemVoice.voices(for: settings.recognitionLocale), id: \.identifier) { voice in
                                Text("\(voice.name) (\(SystemVoice.qualityLabel(voice)))").tag(voice.identifier)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                LabeledContent("Tempo:") {
                    RangeSlider(value: $settings.speechRate, range: 0.35...0.65, low: "Långsamt", high: "Snabbt")
                }
                LabeledContent("Tonhöjd:") {
                    RangeSlider(value: $settings.speechPitch, range: 0.7...1.7, low: "Låg", high: "Hög")
                }
            } else {
                LabeledContent("API-nyckel:") {
                    Explained("Skaffa en nyckel på elevenlabs.io.") {
                        SecureField("API-nyckel", text: $settings.elevenLabsKey)
                            .labelsHidden()
                    }
                }
                LabeledContent("Modell:") {
                    Explained("Eleven v4 Turbo låter naturligt och svarar snabbt. Ett svar från Buddy kostar ungefär en cent.") {
                        Picker("Modell", selection: $settings.elevenLabsModel) {
                            ForEach(ElevenLabsAPI.models) { option in
                                Text(option.label).tag(option.id)
                            }
                            if !ElevenLabsAPI.models.contains(where: { $0.id == settings.elevenLabsModel }) {
                                Text(settings.elevenLabsModel).tag(settings.elevenLabsModel)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                LabeledContent("Röst:") {
                    Explained("Välj en röst som är inspelad på svenska.") {
                        HStack(spacing: 10) {
                            Text(voiceLabel)
                            Button("Välj röst…") {
                                model.voicePickerOpen = true
                            }
                            .disabled(keyMissing)
                        }
                    }
                }
                TextField("Röst-id:", text: $settings.elevenLabsVoiceID)
                LabeledContent("Repliker:") {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Buddy får skratta, sucka och viska (ljudtaggar)", isOn: $settings.elevenLabsAudioTags)
                            .disabled(!ElevenLabsAPI.supportsAudioTags(settings.elevenLabsModel))
                        Toggle("Förbered fasta repliker med Eleven v4 (högst kvalitet)", isOn: $settings.elevenLabsPreparedQuality)
                            .disabled(ElevenLabsAPI.preparedModel(for: settings.elevenLabsModel) == settings.elevenLabsModel)
                    }
                }
            }

            Section {
                HStack {
                    Button("Testa rösten") {
                        model.testAvatar()
                    }
                    Button("Förbered fasta repliker") {
                        model.prepareLines()
                    }
                    .help("Renderar alla fasta repliker i förväg så att de spelas upp direkt och fungerar utan nätverk.")
                }
            }
        }
        .sheet(isPresented: $model.voicePickerOpen) {
            ElevenLabsVoicePicker(model: model, settings: settings)
        }
    }
}

private struct AIPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    @State private var testResult = ""

    var body: some View {
        Form {
            LabeledContent("API-nyckel:") {
                Explained("Skaffa en nyckel på console.anthropic.com.") {
                    SecureField("API-nyckel", text: $settings.anthropicKey)
                        .labelsHidden()
                }
            }
            LabeledContent("Modell:") {
                Explained("Under en dialog skickas det du säger, och några minuter bakåt, till Claude. Snabbare modeller ger kortare väntan på scen.") {
                    Picker("Modell", selection: $settings.claudeModel) {
                        ForEach(ClaudeAPI.modelOptions) { option in
                            Text(option.label).tag(option.id)
                        }
                        if !ClaudeAPI.modelOptions.contains(where: { $0.id == settings.claudeModel }) {
                            Text(settings.claudeModel).tag(settings.claudeModel)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            Section {
                HStack {
                    Button("Testa anslutningen") {
                        testResult = "Testar…"
                        Task { @MainActor in
                            testResult = await model.testClaude()
                        }
                    }
                    Text(testResult)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
        }
    }
}

private struct ListeningPane: View {
    @ObservedObject var settings: AppSettings

    private let languages: [(String, String)] = [
        ("sv-SE", "Svenska"),
        ("en-US", "Engelska (USA)"),
        ("en-GB", "Engelska (Storbritannien)"),
        ("nb-NO", "Norska"),
        ("da-DK", "Danska"),
        ("fi-FI", "Finska"),
        ("de-DE", "Tyska"),
    ]

    var body: some View {
        Form {
            LabeledContent("Språk:") {
                Picker("Språk", selection: $settings.recognitionLocale) {
                    ForEach(languages, id: \.0) { language in
                        Text(language.1).tag(language.0)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            LabeledContent("Taligenkänning:") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("På datorn när det går (fungerar utan nätverk)", isOn: $settings.preferOnDevice)
                    Toggle("Börja lyssna när Buddy startar", isOn: $settings.listenOnLaunch)
                }
            }

            Section {
                LabeledContent("Fraser:") {
                    Explained("Hur exakt trigger- och avslutsfraser måste sägas. Säg triggerfrasen tydligt och avsluta med en kort paus; i kontrollpanelen ser du vad Buddy hör.") {
                        RangeSlider(value: $settings.matchThreshold, range: 0.6...0.95, low: "Förlåtande", high: "Exakta")
                    }
                }
                LabeledContent("Paus före svar:") {
                    Explained("Hur länge Buddy väntar efter triggerfrasen.") {
                        ValueSlider(value: $settings.triggerSilence, range: 0.3...2.5, text: seconds(settings.triggerSilence))
                    }
                }
                LabeledContent("Paus efter fråga:") {
                    Explained("Tystnaden som betyder att du har pratat klart.") {
                        ValueSlider(value: $settings.replySilence, range: 0.6...3.5, text: seconds(settings.replySilence))
                    }
                }
                LabeledContent("Går undan efter:") {
                    ValueSlider(value: $settings.idleTimeout, range: 0...120, step: 5,
                                text: settings.idleTimeout == 0 ? "aldrig" : "\(Int(settings.idleTimeout)) s tystnad")
                }
            }
        }
    }
}

private struct AvatarPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            LabeledContent("Hörn:") {
                Picker("Hörn", selection: $settings.corner) {
                    ForEach(OverlayCorner.allCases) { corner in
                        Text(corner.label).tag(corner)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            LabeledContent("Skärm:") {
                Explained("Avataren ligger över allt annat, även bildspel i helskärm. Syns den inte över Keynote: tillåt andra appar att använda skärmen under bildspel i Keynotes inställningar, eller spela upp bildspelet i ett fönster.") {
                    Picker("Skärm", selection: $settings.screen) {
                        ForEach(OverlayScreen.allCases) { screen in
                            Text(screen.label).tag(screen)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            LabeledContent("Storlek:") {
                ValueSlider(value: $settings.avatarSize, range: 120...380, step: 10, text: "\(Int(settings.avatarSize)) pt")
            }
            LabeledContent("Färg:") {
                HStack(spacing: 10) {
                    Slider(value: $settings.robotHue, in: 0...1)
                    Circle()
                        .fill(Color(hue: settings.robotHue, saturation: 0.75, brightness: 0.95))
                        .frame(width: 16, height: 16)
                        .frame(width: 90, alignment: .leading)
                }
            }
            LabeledContent("Textning:") {
                Toggle("Visa det Buddy säger i en pratbubbla", isOn: $settings.showSubtitles)
            }

            Section {
                Button("Testa avataren") {
                    model.testAvatar()
                }
            }
        }
    }
}

private struct ShortcutsPane: View {
    private let shortcuts = [
        ("Starta nästa moment, eller avsluta dialogen", "⌃⌥⌘B"),
        ("Tyst! Avbryt Buddys replik", "⌃⌥⌘."),
        ("Slå på eller av lyssnandet", "⌃⌥⌘L"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                ForEach(shortcuts, id: \.1) { action, keys in
                    GridRow {
                        Text(action)
                        Text(keys)
                            .gridColumnAlignment(.trailing)
                    }
                }
            }
            Note("Kortkommandona fungerar även när presentationsprogrammet ligger överst.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct UpdatesPane: View {
    @ObservedObject var updater: Updater
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            LabeledContent("Version:", value: updater.currentVersion)
            if !AppMover.isInstalled {
                LabeledContent("Plats:") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Buddy ligger inte i mappen Program.")
                        Button("Flytta till Program…") {
                            AppMover.offerFromSettings()
                        }
                    }
                }
            }
            LabeledContent("Automatiskt:") {
                Explained("Buddy söker efter en ny version en gång om dygnet. Den måste vara signerad av Subtree Communications AB och notariserad av Apple, och installeras när Buddy inte har använts på 20 minuter eller när du avslutar Buddy, aldrig mitt i en dialog.") {
                    Toggle("Hämta och installera nya versioner", isOn: $settings.autoUpdate)
                }
            }
            LabeledContent("Status:") {
                Text(updater.statusText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let lastCheck = updater.lastCheck {
                LabeledContent("Senast kontrollerat:", value: lastCheck.formatted(date: .abbreviated, time: .shortened))
            }

            Section {
                HStack {
                    Button("Sök efter uppdateringar nu") {
                        Task { @MainActor in await updater.check() }
                    }
                    .disabled(updater.status == .checking)
                    if updater.readyToInstall {
                        Button("Installera och starta om") {
                            updater.install(relaunch: true)
                        }
                    }
                }
            }
        }
    }
}
