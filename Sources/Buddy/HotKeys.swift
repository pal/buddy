import Carbon
import Foundation

/// Global keyboard shortcuts (work while another app, e.g. Keynote, is in front).
/// All shortcuts use Control + Option + Command.
final class HotKeyCenter {
    enum Key {
        case b, l, period

        var code: UInt32 {
            switch self {
            case .b: return UInt32(kVK_ANSI_B)
            case .l: return UInt32(kVK_ANSI_L)
            case .period: return UInt32(kVK_ANSI_Period)
            }
        }
    }

    private static var actions: [UInt32: () -> Void] = [:]
    private static var handlerInstalled = false
    private var refs: [EventHotKeyRef] = []

    init() {
        HotKeyCenter.installHandler()
    }

    @discardableResult
    func register(key: Key, action: @escaping () -> Void) -> Bool {
        let id = UInt32(HotKeyCenter.actions.count + 1)
        HotKeyCenter.actions[id] = action
        let hotKeyID = EventHotKeyID(signature: OSType(0x4255_4459), id: id) // "BUDY"
        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(key.code, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs.append(ref)
            return true
        }
        NSLog("Buddy: kunde inte registrera kortkommando (\(status))")
        return false
    }

    deinit {
        for ref in refs {
            UnregisterEventHotKey(ref)
        }
    }

    private static func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            if status == noErr {
                HotKeyCenter.fire(hotKeyID.id)
            }
            return noErr
        }, 1, &eventType, nil, nil)
    }

    private static func fire(_ id: UInt32) {
        DispatchQueue.main.async {
            actions[id]?()
        }
    }
}
