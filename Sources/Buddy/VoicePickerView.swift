import AVFoundation
import SwiftUI
import BuddyCore

/// Plays the short preview clip of a voice.
@MainActor
final class VoicePreviewPlayer: ObservableObject {
    @Published private(set) var playingID: String?
    private var player: AVPlayer?
    private var observer: NSObjectProtocol?

    func toggle(_ voice: ElevenLabsAPI.Voice) {
        if playingID == voice.id {
            stop()
            return
        }
        stop()
        guard let url = voice.previewURL else { return }
        let item = AVPlayerItem(url: url)
        observer = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
        let newPlayer = AVPlayer(playerItem: item)
        player = newPlayer
        playingID = voice.id
        newPlayer.play()
    }

    /// Plays a sentence ElevenLabs rendered with a voice.
    func play(file url: URL, id: String) {
        stop()
        let item = AVPlayerItem(url: url)
        observer = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
        let newPlayer = AVPlayer(playerItem: item)
        player = newPlayer
        playingID = id
        newPlayer.play()
    }

    func stop() {
        player?.pause()
        player = nil
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
        playingID = nil
    }
}

/// Lets the user pick Buddy's ElevenLabs voice: Swedish voices from the Voice Library, or the
/// account's own voices, with a preview of each.
struct ElevenLabsVoicePicker: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    private enum Source: String, CaseIterable, Identifiable {
        case library, mine
        var id: String { rawValue }
        var label: String {
            switch self {
            case .library: return "Svenska röster (Voice Library)"
            case .mine: return "Mina röster och ElevenLabs egna"
            }
        }
    }

    @State private var source: Source = .library
    @State private var library: [ElevenLabsAPI.Voice] = []
    @State private var mine: [ElevenLabsAPI.Voice] = []
    @State private var loading = false
    @State private var message: String?
    @State private var search = ""
    @State private var choosing: String?
    @StateObject private var preview = VoicePreviewPlayer()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Välj röst för Buddy")
                .font(.headline)
            Picker("Källa", selection: $source) {
                ForEach(Source.allCases) { source in
                    Text(source.label).tag(source)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack {
                TextField("Sök på namn, accent eller beskrivning", text: $search)
                    .textFieldStyle(.roundedBorder)
                if loading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            if source == .library {
                Text("Röster från Voice Library kan Buddy bara använda med en betald ElevenLabs-plan. ElevenLabs egna röster, under Mina röster och ElevenLabs egna, fungerar med alla planer.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            List(filtered) { voice in
                row(voice)
            }
            .frame(minHeight: 300)
            Text("Lyssna på några röster och välj en. När du väljer en röst säger den en mening med den modell du har valt, så att du hör hur den låter. En röst som inte fungerar med ditt konto väljs inte. Röster från Voice Library läggs till under Mina röster på ditt ElevenLabs-konto.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Klar") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 580, height: 540)
        .task { await load() }
        .onDisappear { preview.stop() }
    }

    private var voices: [ElevenLabsAPI.Voice] {
        source == .library ? library : mine
    }

    private var filtered: [ElevenLabsAPI.Voice] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return voices }
        return voices.filter { voice in
            [voice.name, voice.details, voice.description].contains { $0.lowercased().contains(query) }
        }
    }

    private func isSelected(_ voice: ElevenLabsAPI.Voice) -> Bool {
        let selected = settings.elevenLabsVoiceID
        guard !selected.isEmpty else { return false }
        if voice.id == selected { return true }
        return source == .library && ElevenLabsAPI.copy(of: voice, in: mine)?.id == selected
    }

    private func row(_ voice: ElevenLabsAPI.Voice) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                preview.toggle(voice)
            } label: {
                Image(systemName: preview.playingID == voice.id ? "stop.circle.fill" : "play.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.borderless)
            .disabled(voice.previewURL == nil)
            .help("Provlyssna")

            VStack(alignment: .leading, spacing: 2) {
                Text(voice.name)
                    .fontWeight(.semibold)
                if !voice.details.isEmpty {
                    Text(voice.details)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if !voice.description.isEmpty {
                    Text(voice.description)
                        .font(.caption)
                        .lineLimit(2)
                }
                if voice.isPremade {
                    Text("ElevenLabs egen röst, fungerar med alla planer")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else if voice.fromLibrary, source == .mine {
                    Text("Från Voice Library, kräver en betald ElevenLabs-plan")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }
            Spacer()
            if isSelected(voice) {
                Label("Vald", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else if choosing == voice.id {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("Använd") { choose(voice) }
                    .disabled(choosing != nil)
            }
        }
        .padding(.vertical, 4)
    }

    private func load() async {
        loading = true
        message = nil
        do {
            library = try await model.elevenLabsLibraryVoices()
        } catch {
            message = error.localizedDescription
        }
        do {
            mine = try await model.elevenLabsMyVoices()
        } catch {
            if message == nil { message = error.localizedDescription }
        }
        if library.isEmpty, !mine.isEmpty, message == nil {
            source = .mine
        }
        loading = false
        EventLog.shared.record("voicePickerLoaded", [
            "library": library.map(\.name),
            "mine": mine.map(\.name),
            "error": message.map { $0 as Any } ?? NSNull(),
        ])
    }

    private func choose(_ voice: ElevenLabsAPI.Voice) {
        choosing = voice.id
        message = nil
        let fromLibrary = source == .library
        Task { @MainActor in
            do {
                let sample = try await model.useElevenLabsVoice(voice, fromLibrary: fromLibrary)
                preview.play(file: sample, id: voice.id)
            } catch {
                message = "\(voice.name) går inte att använda: \(error.localizedDescription)"
            }
            if fromLibrary, let updated = try? await model.elevenLabsMyVoices() {
                mine = updated
            }
            choosing = nil
        }
    }
}
