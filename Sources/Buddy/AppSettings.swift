import Foundation
import Security
import BuddyCore

enum VoiceProvider: String, CaseIterable, Identifiable {
    case system
    case elevenLabs

    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "macOS (inbyggd, gratis, offline)"
        case .elevenLabs: return "ElevenLabs (bäst kvalitet, kräver nyckel)"
        }
    }
}

enum OverlayCorner: String, CaseIterable, Identifiable {
    case bottomRight, bottomLeft, topRight, topLeft

    var id: String { rawValue }
    var label: String {
        switch self {
        case .bottomRight: return "Nere till höger"
        case .bottomLeft: return "Nere till vänster"
        case .topRight: return "Uppe till höger"
        case .topLeft: return "Uppe till vänster"
        }
    }
    var isRight: Bool { self == .bottomRight || self == .topRight }
    var isBottom: Bool { self == .bottomRight || self == .bottomLeft }
}

enum OverlayScreen: String, CaseIterable, Identifiable {
    case main, external, all

    var id: String { rawValue }
    var label: String {
        switch self {
        case .main: return "Huvudskärmen"
        case .external: return "Extern skärm/projektor (om ansluten)"
        case .all: return "Alla skärmar"
        }
    }
}

/// User preferences, stored in UserDefaults (API keys in the Keychain).
@MainActor
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var activeSessionID: String { didSet { save(activeSessionID, "activeSessionID") } }
    @Published var isFirstLaunch: Bool { didSet { defaults.set(!isFirstLaunch, forKey: "hasLaunched") } }
    @Published var listenOnLaunch: Bool { didSet { save(listenOnLaunch, "listenOnLaunch") } }

    // AI
    @Published var anthropicKey: String { didSet { Keychain.write("anthropic", anthropicKey) } }
    @Published var claudeModel: String { didSet { save(claudeModel, "claudeModel") } }

    // Voice
    @Published var voiceProvider: VoiceProvider { didSet { save(voiceProvider.rawValue, "voiceProvider") } }
    @Published var systemVoiceID: String { didSet { save(systemVoiceID, "systemVoiceID") } }
    @Published var speechRate: Double { didSet { save(speechRate, "speechRate") } }
    @Published var speechPitch: Double { didSet { save(speechPitch, "speechPitch") } }
    @Published var elevenLabsKey: String { didSet { Keychain.write("elevenlabs", elevenLabsKey) } }
    @Published var elevenLabsVoiceID: String { didSet { save(elevenLabsVoiceID, "elevenLabsVoiceID") } }
    @Published var elevenLabsModel: String { didSet { save(elevenLabsModel, "elevenLabsModel") } }

    // Listening
    @Published var recognitionLocale: String { didSet { save(recognitionLocale, "recognitionLocale") } }
    @Published var preferOnDevice: Bool { didSet { save(preferOnDevice, "preferOnDevice") } }
    @Published var matchThreshold: Double { didSet { save(matchThreshold, "matchThreshold") } }
    @Published var triggerSilence: Double { didSet { save(triggerSilence, "triggerSilence") } }
    @Published var replySilence: Double { didSet { save(replySilence, "replySilence") } }
    @Published var idleTimeout: Double { didSet { save(idleTimeout, "idleTimeout") } }

    // Avatar
    @Published var corner: OverlayCorner { didSet { save(corner.rawValue, "corner") } }
    @Published var screen: OverlayScreen { didSet { save(screen.rawValue, "screen") } }
    @Published var avatarSize: Double { didSet { save(avatarSize, "avatarSize") } }
    @Published var showSubtitles: Bool { didSet { save(showSubtitles, "showSubtitles") } }
    @Published var robotHue: Double { didSet { save(robotHue, "robotHue") } }

    init() {
        let d = UserDefaults.standard
        func string(_ key: String, _ fallback: String) -> String { d.string(forKey: key) ?? fallback }
        func double(_ key: String, _ fallback: Double) -> Double { d.object(forKey: key) == nil ? fallback : d.double(forKey: key) }
        func bool(_ key: String, _ fallback: Bool) -> Bool { d.object(forKey: key) == nil ? fallback : d.bool(forKey: key) }

        activeSessionID = string("activeSessionID", "")
        isFirstLaunch = !d.bool(forKey: "hasLaunched")
        listenOnLaunch = bool("listenOnLaunch", true)
        anthropicKey = Keychain.read("anthropic")
        claudeModel = string("claudeModel", ClaudeAPI.defaultModel)
        voiceProvider = VoiceProvider(rawValue: string("voiceProvider", "")) ?? .system
        systemVoiceID = string("systemVoiceID", "")
        speechRate = double("speechRate", 0.5)
        speechPitch = double("speechPitch", 1.2)
        elevenLabsKey = Keychain.read("elevenlabs")
        elevenLabsVoiceID = string("elevenLabsVoiceID", "")
        elevenLabsModel = string("elevenLabsModel", "eleven_flash_v2_5")
        recognitionLocale = string("recognitionLocale", "sv-SE")
        preferOnDevice = bool("preferOnDevice", true)
        matchThreshold = double("matchThreshold", 0.75)
        triggerSilence = double("triggerSilence", 0.9)
        replySilence = double("replySilence", 1.4)
        idleTimeout = double("idleTimeout", 30)
        corner = OverlayCorner(rawValue: string("corner", "")) ?? .bottomRight
        screen = OverlayScreen(rawValue: string("screen", "")) ?? .all
        avatarSize = double("avatarSize", 200)
        showSubtitles = bool("showSubtitles", true)
        robotHue = double("robotHue", 0.53)
    }

    var directorSettings: DirectorSettings {
        var s = DirectorSettings()
        s.matchThreshold = matchThreshold
        s.triggerSilence = triggerSilence
        s.replySilence = replySilence
        s.idleTimeout = idleTimeout
        return s
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }
}

/// Minimal Keychain wrapper for API keys.
enum Keychain {
    private static let service = "io.github.pal.buddy"

    static func read(_ account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return "" }
        return value
    }

    static func write(_ account: String, _ value: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(trimmed.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
