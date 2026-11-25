// Small helper for the e2e driver.
// Build: swiftc -parse-as-library e2e/tools/Probe.swift -o Probe
//
//   Probe windows
//       On-screen windows, front to back, as JSON (owner, layer, bounds in points,
//       origin at the top left of the main screen).
//   Probe region <png> <screenWidthPoints> <x> <y> <w> <h> <r> <g> <b>
//       Statistics for a region of a screenshot (points, top-left origin): how many
//       pixels are close to the given color, and the average color.
//   Probe mic <pid>
//       Whether the process records from an audio input right now, according to Core Audio
//       (the same information macOS uses for its microphone indicator).
//   Probe access
//       Whether macOS lets this tool post keyboard and mouse events.
//   Probe click <x> <y>
//       A left click at a point (points, top-left origin), posted like a real mouse.
//   Probe keys <key>...
//       Key presses posted like a real keyboard, e.g. cmd+a cmd+v; the modifier keys are
//       pressed and released around the key as a person does.
//   Probe type <text>
//       Types text, one key press per character.
//   Probe app <pid>
//       How macOS sees a running app: its activation policy (regular = Dock icon) and
//       whether it is the active app.
import AppKit
import ApplicationServices
import CoreAudio
import CoreGraphics
import Foundation

func emit(_ object: Any) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
        fail("could not encode JSON")
    }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func number(_ value: Any?) -> Double {
    (value as? NSNumber)?.doubleValue ?? 0
}

func listWindows() {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
    var windows: [[String: Any]] = []
    for (order, window) in info.enumerated() {
        let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
        windows.append([
            "order": order,
            "owner": window[kCGWindowOwnerName as String] as? String ?? "",
            "pid": Int(number(window[kCGWindowOwnerPID as String])),
            "number": Int(number(window[kCGWindowNumber as String])),
            "layer": Int(number(window[kCGWindowLayer as String])),
            "alpha": number(window[kCGWindowAlpha as String]),
            "x": number(bounds["X"]),
            "y": number(bounds["Y"]),
            "w": number(bounds["Width"]),
            "h": number(bounds["Height"]),
        ])
    }
    emit(windows)
}

func regionStats(_ arguments: [String]) {
    guard arguments.count == 11,
          let screenWidth = Double(arguments[3]),
          let x = Double(arguments[4]), let y = Double(arguments[5]),
          let w = Double(arguments[6]), let h = Double(arguments[7]),
          let r = Double(arguments[8]), let g = Double(arguments[9]), let b = Double(arguments[10])
    else { fail("usage: Probe region <png> <screenWidthPoints> <x> <y> <w> <h> <r> <g> <b>") }
    guard let data = FileManager.default.contents(atPath: arguments[2]),
          let bitmap = NSBitmapImageRep(data: data)
    else { fail("could not read \(arguments[2])") }

    let scale = Double(bitmap.pixelsWide) / screenWidth
    let x0 = max(0, Int(x * scale)), y0 = max(0, Int(y * scale))
    let x1 = min(bitmap.pixelsWide, Int((x + w) * scale)), y1 = min(bitmap.pixelsHigh, Int((y + h) * scale))
    let step = max(1, Int(scale.rounded()))
    var total = 0
    var matching = 0
    var sum = (0.0, 0.0, 0.0)
    var py = y0
    while py < y1 {
        var px = x0
        while px < x1 {
            if let color = bitmap.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) {
                let cr = Double(color.redComponent) * 255
                let cg = Double(color.greenComponent) * 255
                let cb = Double(color.blueComponent) * 255
                total += 1
                sum = (sum.0 + cr, sum.1 + cg, sum.2 + cb)
                if abs(cr - r) < 40, abs(cg - g) < 40, abs(cb - b) < 40 {
                    matching += 1
                }
            }
            px += step
        }
        py += step
    }
    let count = Double(max(total, 1))
    emit([
        "imageWidth": bitmap.pixelsWide,
        "imageHeight": bitmap.pixelsHigh,
        "scale": scale,
        "total": total,
        "matching": matching,
        "fractionMatching": Double(matching) / count,
        "average": [sum.0 / count, sum.1 / count, sum.2 / count],
    ])
}

func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) -> T? {
    var address = AudioObjectPropertyAddress(
        mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    let status = withUnsafeMutablePointer(to: &value) { pointer in
        AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
    }
    return status == noErr ? value : nil
}

func microphoneUse(_ arguments: [String]) {
    guard arguments.count >= 3, let pid = Int32(arguments[2]) else { fail("usage: Probe mic <pid>") }
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    let system = AudioObjectID(kAudioObjectSystemObject)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else {
        fail("could not list audio processes")
    }
    var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else {
        fail("could not list audio processes")
    }
    for object in objects where property(object, kAudioProcessPropertyPID, pid_t(0)) == pid {
        let input = property(object, kAudioProcessPropertyIsRunningInput, UInt32(0)) ?? 0
        let output = property(object, kAudioProcessPropertyIsRunningOutput, UInt32(0)) ?? 0
        emit(["pid": Int(pid), "known": true, "runningInput": input != 0, "runningOutput": output != 0])
        return
    }
    // A process that has never used audio is not in the list.
    emit(["pid": Int(pid), "known": false, "runningInput": false, "runningOutput": false])
}

// MARK: Real keyboard and mouse events

/// Events from the HID system state, posted where the keyboard and the mouse post theirs, so
/// macOS routes them to the active app and the window under the pointer like real ones.
func source() -> CGEventSource? {
    CGEventSource(stateID: .hidSystemState)
}

func post(_ event: CGEvent?, wait microseconds: useconds_t = 30_000) {
    guard let event else { fail("could not create an event") }
    event.post(tap: .cghidEventTap)
    usleep(microseconds)
}

func access() {
    emit(["postEvent": CGPreflightPostEventAccess(), "accessibility": AXIsProcessTrusted()])
}

func click(_ arguments: [String]) {
    guard arguments.count == 4, let x = Double(arguments[2]), let y = Double(arguments[3]) else {
        fail("usage: Probe click <x> <y>")
    }
    let point = CGPoint(x: x, y: y)
    post(CGEvent(mouseEventSource: source(), mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left),
         wait: 150_000)
    for kind in [CGEventType.leftMouseDown, .leftMouseUp] {
        let event = CGEvent(mouseEventSource: source(), mouseType: kind, mouseCursorPosition: point, mouseButton: .left)
        event?.setIntegerValueField(.mouseEventClickState, value: 1)
        post(event, wait: 80_000)
    }
}

/// US layout key codes (the layout of the test machines).
let keyCodes: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
    "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38,
    "k": 40, "n": 45, "m": 46, ",": 43, ".": 47, "return": 36, "tab": 48, "space": 49, "delete": 51,
    "escape": 53, "left": 123, "right": 124, "down": 125, "up": 126,
]

let modifiers: [String: (code: CGKeyCode, flag: CGEventFlags)] = [
    "cmd": (55, .maskCommand), "shift": (56, .maskShift), "opt": (58, .maskAlternate), "ctrl": (59, .maskControl),
]

func press(_ spec: String) {
    var parts = spec.lowercased().split(separator: "+").map(String.init)
    guard let key = parts.popLast(), let code = keyCodes[key] else { fail("unknown key in \(spec)") }
    var held: [(code: CGKeyCode, flag: CGEventFlags)] = []
    var flags: CGEventFlags = []
    for name in parts {
        guard let modifier = modifiers[name] else { fail("unknown modifier in \(spec)") }
        flags.insert(modifier.flag)
        held.append(modifier)
        let down = CGEvent(keyboardEventSource: source(), virtualKey: modifier.code, keyDown: true)
        down?.flags = flags
        post(down)
    }
    for isDown in [true, false] {
        let event = CGEvent(keyboardEventSource: source(), virtualKey: code, keyDown: isDown)
        event?.flags = flags
        post(event, wait: 60_000)
    }
    for modifier in held.reversed() {
        flags.remove(modifier.flag)
        let up = CGEvent(keyboardEventSource: source(), virtualKey: modifier.code, keyDown: false)
        up?.flags = flags
        post(up)
    }
}

func keys(_ arguments: [String]) {
    guard arguments.count >= 3 else { fail("usage: Probe keys <key>...") }
    for spec in arguments.dropFirst(2) {
        press(spec)
        usleep(150_000)
    }
}

func typeText(_ arguments: [String]) {
    guard arguments.count == 3 else { fail("usage: Probe type <text>") }
    for character in arguments[2].utf16 {
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source(), virtualKey: 0, keyDown: isDown)
            var unit = character
            event?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
            post(event, wait: 40_000)
        }
    }
}

func appInfo(_ arguments: [String]) {
    guard arguments.count == 3, let pid = Int32(arguments[2]) else { fail("usage: Probe app <pid>") }
    guard let app = NSRunningApplication(processIdentifier: pid) else { fail("no app with pid \(pid)") }
    let policy: String
    switch app.activationPolicy {
    case .regular: policy = "regular"
    case .accessory: policy = "accessory"
    case .prohibited: policy = "prohibited"
    @unknown default: policy = "unknown"
    }
    emit(["activationPolicy": policy, "active": app.isActive, "bundleID": app.bundleIdentifier ?? ""])
}

@main
enum Probe {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count >= 2 else { fail("usage: Probe windows | region ... | mic <pid> | access | click | keys | type") }
        switch arguments[1] {
        case "windows": listWindows()
        case "region": regionStats(arguments)
        case "mic": microphoneUse(arguments)
        case "access": access()
        case "click": click(arguments)
        case "keys": keys(arguments)
        case "type": typeText(arguments)
        case "app": appInfo(arguments)
        default: fail("unknown command \(arguments[1])")
        }
    }
}
