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
}

/// The settings window. The pages are chosen with a segmented control at the top (not a
/// tab view, which newer macOS versions move into the toolbar), and each page scrolls.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 0) {
            Picker("Inställningar", selection: $model.settingsTab) {
                ForEach(SettingsTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.vertical, 12)
            Divider()
            page
                .formStyle(.grouped)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    @ViewBuilder private var page: some View {
        switch model.settingsTab {
        case .voice: VoiceSettingsTab(model: model, settings: settings)
        case .ai: AISettingsTab(model: model, settings: settings)
        case .listening: ListeningSettingsTab(settings: settings)
        case .avatar: AvatarSettingsTab(model: model, settings: settings)
        case .shortcuts: ShortcutsTab()
        case .updates: UpdateSettingsTab(updater: model.updater, settings: settings)
        }
    }
}

private struct VoiceSettingsTab: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings

    private var voiceLabel: String {
        if !settings.elevenLabsVoiceName.isEmpty { return settings.elevenLabsVoiceName }
        return settings.elevenLabsVoiceID.isEmpty ? "Ingen vald" : settings.elevenLabsVoiceID
    }

    var body: some View {
        Form {
            Picker("Röst", selection: $settings.voiceProvider) {
                ForEach(VoiceProvider.allCases) { provider in
                    Text(provider.label).tag(provider)
                }
            }

            if settings.voiceProvider == .system {
                Picker("macOS-röst", selection: $settings.systemVoiceID) {
                    Text("Bästa tillgängliga för språket").tag("")
                    ForEach(SystemVoice.voices(for: settings.recognitionLocale), id: \.identifier) { voice in
                        Text("\(voice.name) (\(SystemVoice.qualityLabel(voice)))").tag(voice.identifier)
                    }
                }
                Text("Fler och bättre röster: Systeminställningar → Hjälpmedel → Uppläst innehåll → Systemröst → Hantera röster. Ladda ner en svensk röst i premium- eller förbättrad kvalitet.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Slider(value: $settings.speechRate, in: 0.35...0.65) {
                    Text("Tempo")
                }
                Slider(value: $settings.speechPitch, in: 0.7...1.7) {
                    Text("Tonhöjd")
                }
            } else {
                SecureField("API-nyckel", text: $settings.elevenLabsKey)
                Picker("Modell", selection: $settings.elevenLabsModel) {
                    ForEach(ElevenLabsAPI.models) { option in
                        Text(option.label).tag(option.id)
                    }
                    if !ElevenLabsAPI.models.contains(where: { $0.id == settings.elevenLabsModel }) {
                        Text(settings.elevenLabsModel).tag(settings.elevenLabsModel)
                    }
                }
                HStack {
                    Text("Röst")
                    Spacer()
                    Text(voiceLabel)
                        .foregroundColor(.secondary)
                    Button("Välj röst…") {
                        model.voicePickerOpen = true
                    }
                    .disabled(settings.elevenLabsKey.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                TextField("Röst-id", text: $settings.elevenLabsVoiceID)
                Toggle("Ljudtaggar: Buddy får skratta, sucka och viska", isOn: $settings.elevenLabsAudioTags)
                    .disabled(!ElevenLabsAPI.supportsAudioTags(settings.elevenLabsModel))
                Toggle("Förbered fasta repliker med Eleven v4 (högst kvalitet)", isOn: $settings.elevenLabsPreparedQuality)
                    .disabled(ElevenLabsAPI.preparedModel(for: settings.elevenLabsModel) == settings.elevenLabsModel)
                Text("Skaffa en API-nyckel på elevenlabs.io och välj en röst som är inspelad på svenska. Eleven v4 Turbo låter naturligt och svarar snabbt; ett svar från Buddy kostar ungefär en cent. Om ElevenLabs inte svarar används macOS-rösten.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

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
        .sheet(isPresented: $model.voicePickerOpen) {
            ElevenLabsVoicePicker(model: model, settings: settings)
        }
    }
}

private struct AISettingsTab: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    @State private var testResult = ""

    var body: some View {
        Form {
            SecureField("Anthropic API-nyckel", text: $settings.anthropicKey)
            Picker("Modell", selection: $settings.claudeModel) {
                ForEach(ClaudeAPI.modelOptions) { option in
                    Text(option.label).tag(option.id)
                }
                if !ClaudeAPI.modelOptions.contains(where: { $0.id == settings.claudeModel }) {
                    Text(settings.claudeModel).tag(settings.claudeModel)
                }
            }
            Text("Skaffa en nyckel på console.anthropic.com. Under en dialog skickas det du säger (och några minuter bakåt) till Claude. Snabbare modeller ger kortare väntan på scen.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Testa anslutningen") {
                    testResult = "Testar…"
                    Task { @MainActor in
                        testResult = await model.testClaude()
                    }
                }
                Text(testResult)
                    .font(.caption)
                    .lineLimit(3)
            }
        }
    }
}

private struct ListeningSettingsTab: View {
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
            Picker("Språk", selection: $settings.recognitionLocale) {
                ForEach(languages, id: \.0) { language in
                    Text(language.1).tag(language.0)
                }
            }
            Toggle("Taligenkänning på datorn när det går (fungerar utan nätverk)", isOn: $settings.preferOnDevice)
            Toggle("Börja lyssna när Buddy startar", isOn: $settings.listenOnLaunch)

            Slider(value: $settings.matchThreshold, in: 0.6...0.95) {
                Text("Fraser")
            } minimumValueLabel: {
                Text("Förlåtande")
            } maximumValueLabel: {
                Text("Exakta")
            }
            Slider(value: $settings.triggerSilence, in: 0.3...2.5) {
                Text("Paus före svar: \(settings.triggerSilence, specifier: "%.1f") s")
            }
            Slider(value: $settings.replySilence, in: 0.6...3.5) {
                Text("Paus som betyder att du pratat klart: \(settings.replySilence, specifier: "%.1f") s")
            }
            Slider(value: $settings.idleTimeout, in: 0...120, step: 5) {
                Text(settings.idleTimeout == 0
                     ? "Buddy väntar på svar hur länge som helst"
                     : "Buddy går undan efter \(Int(settings.idleTimeout)) s tystnad")
            }
            Text("Tips: säg triggerfrasen tydligt och avsluta frågan med en kort paus. Använd kontrollpanelen för att se vad Buddy hör.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct AvatarSettingsTab: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Picker("Hörn", selection: $settings.corner) {
                ForEach(OverlayCorner.allCases) { corner in
                    Text(corner.label).tag(corner)
                }
            }
            Picker("Skärm", selection: $settings.screen) {
                ForEach(OverlayScreen.allCases) { screen in
                    Text(screen.label).tag(screen)
                }
            }
            Slider(value: $settings.avatarSize, in: 120...380, step: 10) {
                Text("Storlek: \(Int(settings.avatarSize)) pt")
            }
            HStack {
                Slider(value: $settings.robotHue, in: 0...1) {
                    Text("Färg")
                }
                Circle()
                    .fill(Color(hue: settings.robotHue, saturation: 0.75, brightness: 0.95))
                    .frame(width: 18, height: 18)
            }
            Toggle("Visa textning i en pratbubbla", isOn: $settings.showSubtitles)
            Button("Testa avataren") {
                model.testAvatar()
            }
            Text("Avataren ligger över allt annat, även bildspel i helskärm. Syns den inte över Keynote: tillåt andra appar att använda skärmen under bildspel i Keynotes inställningar, eller spela upp bildspelet i ett fönster.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct UpdateSettingsTab: View {
    @ObservedObject var updater: Updater
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            LabeledContent("Version", value: updater.currentVersion)
            if !AppMover.isInstalled {
                HStack {
                    Text("Buddy ligger inte i mappen Program.")
                    Spacer()
                    Button("Flytta till Program…") {
                        AppMover.offerFromSettings()
                    }
                }
            }
            Toggle("Uppdatera automatiskt", isOn: $settings.autoUpdate)
            Text(updater.statusText)
                .fixedSize(horizontal: false, vertical: true)
            if let lastCheck = updater.lastCheck {
                LabeledContent("Senast kontrollerat", value: lastCheck.formatted(date: .abbreviated, time: .shortened))
            }
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
            Text("Buddy söker efter en ny version en gång om dygnet. Den laddas ner och kontrolleras: den måste vara signerad av Subtree Communications AB och notariserad av Apple. Den installeras när Buddy inte har använts på 20 minuter, eller när du avslutar Buddy, aldrig mitt i en dialog.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ShortcutsTab: View {
    var body: some View {
        Form {
            row("⌃⌥⌘ B", "Starta nästa moment nu / avsluta dialogen")
            row("⌃⌥⌘ .", "Tyst! Avbryt Buddys replik")
            row("⌃⌥⌘ L", "Slå på/av lyssnandet")
            Text("Kortkommandona fungerar även när presentationsprogrammet ligger överst.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func row(_ keys: String, _ action: String) -> some View {
        HStack {
            Text(keys)
                .font(.system(.body, design: .monospaced))
                .frame(width: 90, alignment: .leading)
            Text(action)
        }
    }
}
