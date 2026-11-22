import AppKit
import Foundation
import SwiftUI
import BuddyCore

/// Options used by the end-to-end tests to run Buddy in isolation and observe it.
/// They come from environment variables and are all off in normal use.
struct LaunchOptions {
    /// Folder for presentations, audio cache and snapshots instead of the user's (BUDDY_DATA_DIR).
    let dataDirectory: URL?
    /// Presentation file to load and make active (BUDDY_SESSION_FILE).
    let sessionFile: URL?
    /// Claude endpoint, e.g. a local mock server (BUDDY_CLAUDE_URL).
    let claudeURL: URL?
    /// API key used instead of the Keychain (BUDDY_ANTHROPIC_KEY).
    let anthropicKey: String?
    /// ElevenLabs API base URL, e.g. a local mock server (BUDDY_ELEVENLABS_URL).
    let elevenLabsURL: URL?
    /// Where Buddy looks for new releases instead of GitHub (BUDDY_UPDATE_FEED).
    let updateFeedURL: URL?
    /// Folder that stands in for /Applications, so the tests can check that Buddy moves itself
    /// there (BUDDY_APPLICATIONS_DIR). Buddy only offers to move while testing if this is set.
    let applicationsFolder: URL?
    /// JSON Lines file where Buddy records what it does (BUDDY_EVENT_LOG).
    let eventLog: URL?
    /// File with test input, one JSON object per line: {"say": "..."} or {"command": "..."}.
    /// When set, it replaces the microphone (BUDDY_INBOX).
    let inbox: URL?
    /// File watched for commands while the real microphone is used (BUDDY_COMMANDS).
    let commands: URL?
    /// Setting overrides from BUDDY_SET_<name>=<value>, e.g. BUDDY_SET_corner=bottomLeft.
    let settingOverrides: [String: String]

    init(environment: [String: String]) {
        func url(_ key: String) -> URL? {
            guard let value = environment[key], !value.isEmpty else { return nil }
            return value.contains("://") ? URL(string: value) : URL(fileURLWithPath: value)
        }
        dataDirectory = url("BUDDY_DATA_DIR")
        sessionFile = url("BUDDY_SESSION_FILE")
        claudeURL = url("BUDDY_CLAUDE_URL")
        anthropicKey = environment["BUDDY_ANTHROPIC_KEY"]
        elevenLabsURL = url("BUDDY_ELEVENLABS_URL")
        updateFeedURL = url("BUDDY_UPDATE_FEED")
        applicationsFolder = url("BUDDY_APPLICATIONS_DIR")
        eventLog = url("BUDDY_EVENT_LOG")
        inbox = url("BUDDY_INBOX")
        commands = url("BUDDY_COMMANDS")
        var overrides: [String: String] = [:]
        for (key, value) in environment where key.hasPrefix("BUDDY_SET_") {
            overrides[String(key.dropFirst("BUDDY_SET_".count))] = value
        }
        settingOverrides = overrides
    }

    static let current = LaunchOptions(environment: ProcessInfo.processInfo.environment)

    var isTesting: Bool { dataDirectory != nil || eventLog != nil || inbox != nil }
}

/// Writes what Buddy does as JSON Lines, for the end-to-end tests. Does nothing unless
/// BUDDY_EVENT_LOG is set.
@MainActor
final class EventLog {
    static let shared = EventLog(url: LaunchOptions.current.eventLog)

    private let handle: FileHandle?
    private let start = Date()

    init(url: URL?) {
        guard let url else {
            handle = nil
            return
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Appends, so a Buddy that restarts itself after an update keeps writing to the same log.
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    var isEnabled: Bool { handle != nil }

    func record(_ type: String, _ fields: [String: Any] = [:]) {
        guard let handle else { return }
        var object = fields
        object["type"] = type
        object["t"] = (Date().timeIntervalSince(start) * 1000).rounded() / 1000
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return }
        try? handle.write(contentsOf: data + Data("\n".utf8))
    }

    static func frame(_ rect: NSRect) -> [String: Double] {
        ["x": Double(rect.minX), "y": Double(rect.minY), "w": Double(rect.width), "h": Double(rect.height)]
    }
}

struct InboxCommand {
    let name: String
    let value: String?
}

/// Reads new JSON lines appended to a file.
@MainActor
final class LineFileReader {
    private let url: URL
    private var offset: UInt64 = 0

    init(url: URL) {
        self.url = url
    }

    func readNewObjects() -> [[String: Any]] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(),
              let lastNewline = data.lastIndex(of: 0x0A)
        else { return [] }
        let complete = data.prefix(through: lastNewline)
        offset += UInt64(complete.count)
        return String(decoding: complete, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { line in
                (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
            }
    }

    static func command(from object: [String: Any]) -> InboxCommand? {
        guard let name = object["command"] as? String else { return nil }
        let value: String?
        switch object["value"] {
        case let string as String: value = string
        case let number as NSNumber: value = number.stringValue
        default: value = nil
        }
        return InboxCommand(name: name, value: value)
    }
}

/// Test input that replaces the microphone: sentences from the inbox file are delivered as
/// recognition results, word by word, while Buddy is listening.
@MainActor
final class InboxInput: SpeechInput {
    var onTranscript: ((Int, String) -> Void)?
    var onLog: ((String) -> Void)?
    var onCommand: ((InboxCommand) -> Void)?

    private(set) var isRunning = false
    var level: Float { emitting == nil ? 0 : 0.05 }

    private struct Utterance {
        let text: String
        let wordDelay: Double
    }

    private let reader: LineFileReader
    private var pending: [Utterance] = []
    private var segment = 0
    private var emitting: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?

    init(url: URL) {
        reader = LineFileReader(url: url)
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self else { return }
                self.poll()
            }
        }
    }

    func start(locale: String, contextualStrings: [String], preferOnDevice: Bool) {
        guard !isRunning else { return }
        isRunning = true
        EventLog.shared.record("inputStarted", ["source": "inbox"])
        emitNext()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        emitting?.cancel()
        emitting = nil
        EventLog.shared.record("inputStopped", ["source": "inbox"])
    }

    func restartSegment() {}

    func setVocabulary(_ strings: [String]) {}

    private func poll() {
        for object in reader.readNewObjects() {
            if let text = object["say"] as? String {
                let delay = (object["wordDelay"] as? Double) ?? 0.15
                pending.append(Utterance(text: text, wordDelay: delay))
            } else if let command = LineFileReader.command(from: object) {
                onCommand?(command)
            }
        }
        emitNext()
    }

    private func emitNext() {
        guard isRunning, emitting == nil, !pending.isEmpty else { return }
        let utterance = pending.removeFirst()
        segment += 1
        let id = segment
        EventLog.shared.record("inputUtterance", ["segment": id, "text": utterance.text])
        emitting = Task { @MainActor [weak self] in
            let words = utterance.text.split(separator: " ").map(String.init)
            var heard: [String] = []
            for word in words {
                try? await Task.sleep(nanoseconds: UInt64(utterance.wordDelay * 1_000_000_000))
                guard let self, !Task.isCancelled, self.isRunning else { return }
                heard.append(word)
                self.onTranscript?(id, heard.joined(separator: " "))
            }
            guard let self else { return }
            self.emitting = nil
            self.emitNext()
        }
    }
}

/// Renders the robot off screen, so tests can check that the mouth is drawn open while speaking.
@MainActor
enum RobotSnapshot {
    static func image(mode: AvatarState.Mode, mouth: CGFloat, hue: Double, size: CGFloat = 200) -> CGImage? {
        // A fixed time keeps the eyes open and the head still, so only the mouth differs.
        let view = RobotFigure(t: 1.0, mode: mode, mouth: mouth, hue: hue)
            .frame(width: size, height: size * 1.2)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return renderer.cgImage
    }

    @discardableResult
    static func write(_ image: CGImage, to url: URL) -> Bool {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: url)) != nil
    }

    /// Fraction of pixels that differ clearly between two images of the same size.
    static func difference(_ a: CGImage, _ b: CGImage) -> Double {
        guard a.width == b.width, a.height == b.height, let pa = rgba(a), let pb = rgba(b) else { return 0 }
        let pixels = a.width * a.height
        var differing = 0
        for i in 0..<pixels {
            let o = i * 4
            var delta = 0
            for c in 0..<4 {
                delta += abs(Int(pa[o + c]) - Int(pb[o + c]))
            }
            if delta > 40 { differing += 1 }
        }
        return Double(differing) / Double(max(pixels, 1))
    }

    private static func rgba(_ image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }
}
