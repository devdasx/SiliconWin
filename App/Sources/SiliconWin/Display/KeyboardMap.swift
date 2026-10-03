import AppKit
import Carbon.HIToolbox

/// Mac virtual key codes → PC (XT, scan code set 1) codes as QEMU expects them
/// in its extended key event: extended keys (E0 prefix) have bit 0x80 set.
/// Windows applies its own keyboard layout, so the physical key position is
/// what matters, not the character.
enum KeyboardMap {
    static let scancodes: [UInt16: UInt32] = [
        UInt16(kVK_ANSI_A): 0x1E, UInt16(kVK_ANSI_S): 0x1F, UInt16(kVK_ANSI_D): 0x20, UInt16(kVK_ANSI_F): 0x21,
        UInt16(kVK_ANSI_H): 0x23, UInt16(kVK_ANSI_G): 0x22, UInt16(kVK_ANSI_Z): 0x2C, UInt16(kVK_ANSI_X): 0x2D,
        UInt16(kVK_ANSI_C): 0x2E, UInt16(kVK_ANSI_V): 0x2F, UInt16(kVK_ISO_Section): 0x56, UInt16(kVK_ANSI_B): 0x30,
        UInt16(kVK_ANSI_Q): 0x10, UInt16(kVK_ANSI_W): 0x11, UInt16(kVK_ANSI_E): 0x12, UInt16(kVK_ANSI_R): 0x13,
        UInt16(kVK_ANSI_Y): 0x15, UInt16(kVK_ANSI_T): 0x14, UInt16(kVK_ANSI_1): 0x02, UInt16(kVK_ANSI_2): 0x03,
        UInt16(kVK_ANSI_3): 0x04, UInt16(kVK_ANSI_4): 0x05, UInt16(kVK_ANSI_6): 0x07, UInt16(kVK_ANSI_5): 0x06,
        UInt16(kVK_ANSI_Equal): 0x0D, UInt16(kVK_ANSI_9): 0x0A, UInt16(kVK_ANSI_7): 0x08, UInt16(kVK_ANSI_Minus): 0x0C,
        UInt16(kVK_ANSI_8): 0x09, UInt16(kVK_ANSI_0): 0x0B, UInt16(kVK_ANSI_RightBracket): 0x1B, UInt16(kVK_ANSI_O): 0x18,
        UInt16(kVK_ANSI_U): 0x16, UInt16(kVK_ANSI_LeftBracket): 0x1A, UInt16(kVK_ANSI_I): 0x17, UInt16(kVK_ANSI_P): 0x19,
        UInt16(kVK_Return): 0x1C, UInt16(kVK_ANSI_L): 0x26, UInt16(kVK_ANSI_J): 0x24, UInt16(kVK_ANSI_Quote): 0x28,
        UInt16(kVK_ANSI_K): 0x25, UInt16(kVK_ANSI_Semicolon): 0x27, UInt16(kVK_ANSI_Backslash): 0x2B,
        UInt16(kVK_ANSI_Comma): 0x33, UInt16(kVK_ANSI_Slash): 0x35, UInt16(kVK_ANSI_N): 0x31, UInt16(kVK_ANSI_M): 0x32,
        UInt16(kVK_ANSI_Period): 0x34, UInt16(kVK_Tab): 0x0F, UInt16(kVK_Space): 0x39, UInt16(kVK_ANSI_Grave): 0x29,
        UInt16(kVK_Delete): 0x0E, UInt16(kVK_Escape): 0x01,

        // Modifiers
        UInt16(kVK_Command): 0xDB, UInt16(kVK_RightCommand): 0xDC,
        UInt16(kVK_Shift): 0x2A, UInt16(kVK_RightShift): 0x36,
        UInt16(kVK_Option): 0x38, UInt16(kVK_RightOption): 0xB8,
        UInt16(kVK_Control): 0x1D, UInt16(kVK_RightControl): 0x9D,
        UInt16(kVK_CapsLock): 0x3A,

        // Function keys (F13–F15 sit where PC keyboards have PrtSc/ScrLk/Pause)
        UInt16(kVK_F1): 0x3B, UInt16(kVK_F2): 0x3C, UInt16(kVK_F3): 0x3D, UInt16(kVK_F4): 0x3E,
        UInt16(kVK_F5): 0x3F, UInt16(kVK_F6): 0x40, UInt16(kVK_F7): 0x41, UInt16(kVK_F8): 0x42,
        UInt16(kVK_F9): 0x43, UInt16(kVK_F10): 0x44, UInt16(kVK_F11): 0x57, UInt16(kVK_F12): 0x58,
        UInt16(kVK_F13): 0xB7, UInt16(kVK_F14): 0x46, UInt16(kVK_F15): 0xC6,
        UInt16(kVK_F16): 0x67, UInt16(kVK_F17): 0x68, UInt16(kVK_F18): 0x69, UInt16(kVK_F19): 0x6A, UInt16(kVK_F20): 0x6B,

        // Navigation (Help sits where PC keyboards have Insert)
        UInt16(kVK_Help): 0xD2, UInt16(kVK_Home): 0xC7, UInt16(kVK_PageUp): 0xC9, UInt16(kVK_ForwardDelete): 0xD3,
        UInt16(kVK_End): 0xCF, UInt16(kVK_PageDown): 0xD1,
        UInt16(kVK_LeftArrow): 0xCB, UInt16(kVK_RightArrow): 0xCD, UInt16(kVK_DownArrow): 0xD0, UInt16(kVK_UpArrow): 0xC8,

        // Keypad
        UInt16(kVK_ANSI_KeypadDecimal): 0x53, UInt16(kVK_ANSI_KeypadMultiply): 0x37, UInt16(kVK_ANSI_KeypadPlus): 0x4E,
        UInt16(kVK_ANSI_KeypadClear): 0x45, UInt16(kVK_ANSI_KeypadDivide): 0xB5, UInt16(kVK_ANSI_KeypadEnter): 0x9C,
        UInt16(kVK_ANSI_KeypadMinus): 0x4A, UInt16(kVK_ANSI_KeypadEquals): 0x59,
        UInt16(kVK_ANSI_Keypad0): 0x52, UInt16(kVK_ANSI_Keypad1): 0x4F, UInt16(kVK_ANSI_Keypad2): 0x50,
        UInt16(kVK_ANSI_Keypad3): 0x51, UInt16(kVK_ANSI_Keypad4): 0x4B, UInt16(kVK_ANSI_Keypad5): 0x4C,
        UInt16(kVK_ANSI_Keypad6): 0x4D, UInt16(kVK_ANSI_Keypad7): 0x47, UInt16(kVK_ANSI_Keypad8): 0x48,
        UInt16(kVK_ANSI_Keypad9): 0x49,

        // Media
        UInt16(kVK_VolumeUp): 0xB0, UInt16(kVK_VolumeDown): 0xAE, UInt16(kVK_Mute): 0xA0,

        // JIS
        UInt16(kVK_JIS_Yen): 0x7D, UInt16(kVK_JIS_Underscore): 0x73, UInt16(kVK_JIS_KeypadComma): 0x7E,
        UInt16(kVK_JIS_Eisu): 0x7B, UInt16(kVK_JIS_Kana): 0x70,
    ]

    /// Characters → (Mac key code, shift) on a US layout. Used for synthetic
    /// key events that carry text but no real key code (text expanders,
    /// accessibility and automation tools post them with key code 0).
    static let usCharacters: [Character: (UInt16, Bool)] = {
        var map: [Character: (UInt16, Bool)] = [:]
        let letters: [(Character, Int)] = [
            ("a", kVK_ANSI_A), ("b", kVK_ANSI_B), ("c", kVK_ANSI_C), ("d", kVK_ANSI_D), ("e", kVK_ANSI_E),
            ("f", kVK_ANSI_F), ("g", kVK_ANSI_G), ("h", kVK_ANSI_H), ("i", kVK_ANSI_I), ("j", kVK_ANSI_J),
            ("k", kVK_ANSI_K), ("l", kVK_ANSI_L), ("m", kVK_ANSI_M), ("n", kVK_ANSI_N), ("o", kVK_ANSI_O),
            ("p", kVK_ANSI_P), ("q", kVK_ANSI_Q), ("r", kVK_ANSI_R), ("s", kVK_ANSI_S), ("t", kVK_ANSI_T),
            ("u", kVK_ANSI_U), ("v", kVK_ANSI_V), ("w", kVK_ANSI_W), ("x", kVK_ANSI_X), ("y", kVK_ANSI_Y),
            ("z", kVK_ANSI_Z),
        ]
        for (char, code) in letters {
            map[char] = (UInt16(code), false)
            map[Character(char.uppercased())] = (UInt16(code), true)
        }
        let pairs: [(Character, Character, Int)] = [
            ("1", "!", kVK_ANSI_1), ("2", "@", kVK_ANSI_2), ("3", "#", kVK_ANSI_3), ("4", "$", kVK_ANSI_4),
            ("5", "%", kVK_ANSI_5), ("6", "^", kVK_ANSI_6), ("7", "&", kVK_ANSI_7), ("8", "*", kVK_ANSI_8),
            ("9", "(", kVK_ANSI_9), ("0", ")", kVK_ANSI_0), ("-", "_", kVK_ANSI_Minus), ("=", "+", kVK_ANSI_Equal),
            ("[", "{", kVK_ANSI_LeftBracket), ("]", "}", kVK_ANSI_RightBracket), ("\\", "|", kVK_ANSI_Backslash),
            (";", ":", kVK_ANSI_Semicolon), ("'", "\"", kVK_ANSI_Quote), (",", "<", kVK_ANSI_Comma),
            (".", ">", kVK_ANSI_Period), ("/", "?", kVK_ANSI_Slash), ("`", "~", kVK_ANSI_Grave),
        ]
        for (plain, shifted, code) in pairs {
            map[plain] = (UInt16(code), false)
            map[shifted] = (UInt16(code), true)
        }
        map[" "] = (UInt16(kVK_Space), false)
        map["\t"] = (UInt16(kVK_Tab), false)
        map["\r"] = (UInt16(kVK_Return), false)
        map["\n"] = (UInt16(kVK_Return), false)
        return map
    }()

    static let leftShift: UInt32 = 0x2A
    static let leftControl: UInt32 = 0x1D
    static let leftAlt: UInt32 = 0x38
    static let windowsKey: UInt32 = 0xDB
    static let delete: UInt32 = 0xD3

    /// Device-dependent modifier bits (NX_DEVICE*KEYMASK) for each modifier key.
    static let modifierMasks: [UInt16: UInt] = [
        UInt16(kVK_Control): 0x0001, UInt16(kVK_RightControl): 0x2000,
        UInt16(kVK_Shift): 0x0002, UInt16(kVK_RightShift): 0x0004,
        UInt16(kVK_Command): 0x0008, UInt16(kVK_RightCommand): 0x0010,
        UInt16(kVK_Option): 0x0020, UInt16(kVK_RightOption): 0x0040,
    ]

    /// With "Mac shortcuts" on, ⌘ plus one of these keys becomes Ctrl plus the key
    /// in Windows (⌘C copy, ⌘V paste, ⌘Z undo, …).
    static let commandShortcutKeys: Set<UInt16> = [
        UInt16(kVK_ANSI_A), UInt16(kVK_ANSI_C), UInt16(kVK_ANSI_V), UInt16(kVK_ANSI_X), UInt16(kVK_ANSI_Z),
        UInt16(kVK_ANSI_Y), UInt16(kVK_ANSI_S), UInt16(kVK_ANSI_F), UInt16(kVK_ANSI_P), UInt16(kVK_ANSI_N),
        UInt16(kVK_ANSI_O), UInt16(kVK_ANSI_T), UInt16(kVK_ANSI_W), UInt16(kVK_ANSI_R), UInt16(kVK_ANSI_L),
        UInt16(kVK_ANSI_B), UInt16(kVK_ANSI_I), UInt16(kVK_ANSI_U), UInt16(kVK_ANSI_K),
        UInt16(kVK_ANSI_Equal), UInt16(kVK_ANSI_Minus), UInt16(kVK_ANSI_0),
    ]
}

/// Turns AppKit key events into scan codes for the guest, tracking which keys
/// are down so nothing stays stuck when the window loses focus.
final class KeyboardTranslator {
    /// Sends one scan code to the guest (down or up).
    var send: (UInt32, Bool) -> Void = { _, _ in }
    /// ⌘C/⌘V/… → Ctrl+C/Ctrl+V/…, ⌘ alone → Windows key.
    var macShortcuts = true

    private var pressed: [UInt16: [UInt32]] = [:]   // mac key code → scan codes sent for it

    /// `defaults write app.siliconwin.SiliconWin DebugKeyboard -bool YES` logs
    /// every key event to /tmp/siliconwin-keyboard.log.
    private static let debugLog: FileHandle? = {
        guard UserDefaults.standard.bool(forKey: "DebugKeyboard") else { return nil }
        let path = "/tmp/siliconwin-keyboard.log"
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()

    private func trace(_ what: String, _ event: NSEvent) {
        guard let log = Self.debugLog else { return }
        let chars = (event.characters ?? "nil").unicodeScalars.map { String(format: "%04X", $0.value) }.joined(separator: ",")
        let pid = event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) ?? -1
        let line = "\(what) pid=\(pid) key=\(event.keyCode) chars=[\(chars)] repeat=\(event.type == .keyDown ? String(event.isARepeat) : "-") flags=\(String(event.modifierFlags.rawValue, radix: 16)) pressed=\(pressed.keys.sorted())\n"
        log.write(Data(line.utf8))
    }
    private var commandHeld = false
    private var commandUsed = false
    private var windowsKeySent = false

    /// Events posted by software (automation and accessibility tools, text
    /// expanders) carry the posting process's PID; hardware key presses don't.
    /// Such tools typically post every character with key code 0 (the A key)
    /// and often never deliver the key-up, so they are typed as characters
    /// (US layout) instead of physical keys. Real key presses always take the
    /// physical-key path, whatever input source (e.g. Arabic) the Mac uses.
    static func isSynthetic(_ event: NSEvent) -> Bool {
        (event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) ?? 0) != 0
    }

    private func syntheticCharacter(_ event: NSEvent) -> Character? {
        guard Self.isSynthetic(event), event.keyCode == 0,
              event.modifierFlags.intersection([.control, .option, .command]).isEmpty,
              let text = event.characters, text.count == 1, let character = text.first else { return nil }
        return character
    }

    /// Synthetic shortcut (e.g. Ctrl+A posted without separate modifier
    /// events): press the modifiers the event carries around the key.
    private func syntheticShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.control, .option, .command, .shift])
        guard Self.isSynthetic(event), !flags.intersection([.control, .option, .command]).isEmpty,
              let scancode = KeyboardMap.scancodes[event.keyCode] else { return false }
        var modifiers: [UInt32] = []
        if flags.contains(.control) { modifiers.append(KeyboardMap.leftControl) }
        if flags.contains(.option) { modifiers.append(KeyboardMap.leftAlt) }
        if flags.contains(.shift) { modifiers.append(KeyboardMap.leftShift) }
        if flags.contains(.command) {
            let asControl = macShortcuts && KeyboardMap.commandShortcutKeys.contains(event.keyCode)
            modifiers.append(asControl ? KeyboardMap.leftControl : KeyboardMap.windowsKey)
        }
        let held = Set(pressed.values.flatMap { $0 })
        let toPress = modifiers.filter { !held.contains($0) }
        toPress.forEach { send($0, true) }
        send(scancode, true)
        send(scancode, false)
        toPress.reversed().forEach { send($0, false) }
        return true
    }

    func keyDown(_ event: NSEvent) {
        trace("down", event)
        guard !event.isARepeat else { return }      // Windows does its own key repeat
        if syntheticShortcut(event) { return }
        if let character = syntheticCharacter(event) {
            guard let (macKey, shift) = KeyboardMap.usCharacters[character],
                  let scancode = KeyboardMap.scancodes[macKey] else { return }
            if shift { send(KeyboardMap.leftShift, true) }
            send(scancode, true)
            send(scancode, false)
            if shift { send(KeyboardMap.leftShift, false) }
            return
        }
        let keyCode = event.keyCode
        guard let scancode = KeyboardMap.scancodes[keyCode] else { return }
        // A key we still think is down (its key-up got lost): release it first
        // so the new press is never dropped.
        if let stale = pressed.removeValue(forKey: keyCode) {
            for code in stale.reversed() { send(code, false) }
        }

        if macShortcuts && commandHeld {
            commandUsed = true
            if KeyboardMap.commandShortcutKeys.contains(keyCode) {
                send(KeyboardMap.leftControl, true)
                send(scancode, true)
                pressed[keyCode] = [KeyboardMap.leftControl, scancode]
                return
            }
            if !windowsKeySent {
                send(KeyboardMap.windowsKey, true)
                windowsKeySent = true
            }
        }
        send(scancode, true)
        pressed[keyCode] = [scancode]
    }

    func keyUp(_ event: NSEvent) {
        trace("up", event)
        // Synthetic characters and shortcuts were already pressed and released.
        if Self.isSynthetic(event) && (event.keyCode == 0 || !event.modifierFlags.intersection([.control, .option, .command]).isEmpty) {
            if pressed[event.keyCode] == nil { return }
        }
        guard let codes = pressed.removeValue(forKey: event.keyCode) else { return }
        for code in codes.reversed() { send(code, false) }
    }

    func flagsChanged(_ event: NSEvent) {
        let keyCode = event.keyCode
        guard let scancode = KeyboardMap.scancodes[keyCode] else { return }

        if keyCode == UInt16(kVK_CapsLock) {
            // macOS reports Caps Lock as a toggle: forward a full press each time.
            send(scancode, true)
            send(scancode, false)
            return
        }
        guard let mask = KeyboardMap.modifierMasks[keyCode] else { return }
        let isDown = event.modifierFlags.rawValue & mask != 0
        let isCommand = keyCode == UInt16(kVK_Command) || keyCode == UInt16(kVK_RightCommand)

        if isCommand && macShortcuts {
            if isDown {
                commandHeld = true
                commandUsed = false
                windowsKeySent = false
            } else {
                commandHeld = false
                if windowsKeySent {
                    send(KeyboardMap.windowsKey, false)
                } else if !commandUsed {
                    // ⌘ pressed on its own: open Start like the Windows key.
                    send(KeyboardMap.windowsKey, true)
                    send(KeyboardMap.windowsKey, false)
                }
                windowsKeySent = false
            }
            return
        }

        if isDown, pressed[keyCode] == nil {
            send(scancode, true)
            pressed[keyCode] = [scancode]
        } else if !isDown, let codes = pressed.removeValue(forKey: keyCode) {
            for code in codes.reversed() { send(code, false) }
        }
    }

    /// Releases everything (window lost focus, VM view hidden, …).
    func releaseAll() {
        for codes in pressed.values {
            for code in codes.reversed() { send(code, false) }
        }
        pressed.removeAll()
        if windowsKeySent { send(KeyboardMap.windowsKey, false) }
        commandHeld = false
        commandUsed = false
        windowsKeySent = false
    }
}
