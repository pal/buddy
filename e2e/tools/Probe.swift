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
import AppKit
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

@main
enum Probe {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count >= 2 else { fail("usage: Probe windows | region ... | mic <pid>") }
        switch arguments[1] {
        case "windows": listWindows()
        case "region": regionStats(arguments)
        case "mic": microphoneUse(arguments)
        default: fail("unknown command \(arguments[1])")
        }
    }
}
