import AppKit
import Carbon.HIToolbox

/// A global keyboard shortcut: a physical key plus Carbon modifier flags.
/// Key codes, not characters, so it works the same on every keyboard layout.
struct Shortcut: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32

    static let control = UInt32(controlKey)
    static let option = UInt32(optionKey)
    static let shift = UInt32(shiftKey)
    static let command = UInt32(cmdKey)

    /// Reads an override from `UserDefaults` as `[keyCode, modifiers]`, so a
    /// shortcut can be changed before there is a screen for it.
    static func stored(_ key: String, default fallback: Shortcut) -> Shortcut {
        guard let pair = UserDefaults.standard.array(forKey: key) as? [Int], pair.count == 2,
              pair[0] >= 0, pair[1] >= 0
        else { return fallback }
        return Shortcut(keyCode: UInt32(pair[0]), modifiers: UInt32(pair[1]))
    }

    /// "⌃⌥→", in the order macOS menus use.
    var label: String {
        var text = ""
        if modifiers & Self.control != 0 { text += "⌃" }
        if modifiers & Self.option != 0 { text += "⌥" }
        if modifiers & Self.shift != 0 { text += "⇧" }
        if modifiers & Self.command != 0 { text += "⌘" }
        return text + (Self.keyNames[Int(keyCode)] ?? "#\(keyCode)")
    }

    private static let keyNames: [Int: String] = [
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
        kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
        kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
        kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
        kVK_ANSI_Z: "Z", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_Space: "Space",
    ]
}

/// System-wide hotkeys through Carbon's `RegisterEventHotKey`.
///
/// No permission is needed for these (unlike an event tap), and the key press
/// is not passed on to the app in front. Only the exact combinations
/// registered are taken.
@MainActor
final class HotKeys {
    static let shared = HotKeys()

    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private var nextID: UInt32 = 1
    /// "CYCL"
    private let signature: OSType = 0x4359_434C

    /// Returns a handle for `unregister`, or nil if macOS refused the combination.
    func register(_ shortcut: Shortcut, action: @escaping () -> Void) -> UInt32? {
        installHandler()
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode, shortcut.modifiers,
            EventHotKeyID(signature: signature, id: id),
            GetEventDispatcherTarget(), 0, &ref
        )
        guard status == noErr, let ref else { return nil }
        refs[id] = ref
        actions[id] = action
        return id
    }

    func unregister(_ id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        actions[id] = nil
    }

    fileprivate func fire(_ id: UInt32) { actions[id]?() }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            var key = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &key
            )
            guard status == noErr else { return status }
            let id = key.id
            // Carbon delivers hotkeys on the main thread's run loop.
            MainActor.assumeIsolated { HotKeys.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}
