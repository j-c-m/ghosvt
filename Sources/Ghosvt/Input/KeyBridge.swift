import AppKit
import CGhosttyVT

enum KeyBridge {
    /// ⌘1…⌘9 / ⌘0 or ⌘F1…⌘F12 → VT index (0-based), else nil.
    static func vtSwitchIndex(from event: NSEvent, vtCount: Int) -> Int? {
        guard event.type == .keyDown || event.type == .keyUp else { return nil }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Command required; do not treat Option/Control-only as VT switch.
        guard flags.contains(.command) else { return nil }
        // Leave pure app quit alone (⌘Q handled elsewhere).
        if flags.contains(.shift) || flags.contains(.control) { return nil }

        let keyCode = event.keyCode

        // Main keyboard 1–9,0
        let mainDigitKeys: [UInt16: Int] = [
            18: 1, 19: 2, 20: 3, 21: 4, 23: 5,
            22: 6, 26: 7, 28: 8, 25: 9, 29: 10,
        ]
        // Numeric keypad 1–9,0
        let padDigitKeys: [UInt16: Int] = [
            83: 1, 84: 2, 85: 3, 86: 4, 87: 5,
            88: 6, 89: 7, 91: 8, 92: 9, 82: 10,
        ]
        if let n = mainDigitKeys[keyCode] ?? padDigitKeys[keyCode], n >= 1, n <= vtCount {
            return n - 1
        }

        if let raw = event.charactersIgnoringModifiers, raw.count == 1, let ch = raw.first {
            if ch >= "1", ch <= "9" {
                let n = Int(ch.asciiValue! - UInt8(ascii: "0"))
                if n >= 1, n <= vtCount { return n - 1 }
            }
            if ch == "0", vtCount >= 10 {
                return 9
            }
        }

        // F1–F12
        let fKeys: [UInt16] = [
            122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
        ]
        if let idx = fKeys.firstIndex(of: keyCode), idx < vtCount {
            return idx
        }

        return nil
    }

    /// ⌘← / ⌘→ → -1 / +1, else nil.
    static func vtSwitchDelta(from event: NSEvent) -> Int? {
        guard event.type == .keyDown else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command),
              !flags.contains(.shift),
              !flags.contains(.control),
              !flags.contains(.option)
        else { return nil }
        switch event.keyCode {
        case 123: return -1 // left
        case 124: return 1  // right
        default: return nil
        }
    }

    static func handleKeyDown(_ event: NSEvent, session: TerminalSession) {
        // Encode under the session lock, then write *outside* the lock.
        // Nested writeToPty while holding the lock deadlocked NSLock on first key.
        let payload: [UInt8]? = session.encodeKeyDown(event)
        if let payload, !payload.isEmpty {
            session.writeToPty(payload)
        }
    }

    static func mapMods(_ flags: NSEvent.ModifierFlags) -> GhosttyMods {
        var mods: GhosttyMods = 0
        if flags.contains(.shift) { mods |= GhosttyMods(GHOSTTY_MODS_SHIFT) }
        if flags.contains(.control) { mods |= GhosttyMods(GHOSTTY_MODS_CTRL) }
        if flags.contains(.option) { mods |= GhosttyMods(GHOSTTY_MODS_ALT) }
        if flags.contains(.command) { mods |= GhosttyMods(GHOSTTY_MODS_SUPER) }
        if flags.contains(.capsLock) { mods |= GhosttyMods(GHOSTTY_MODS_CAPS_LOCK) }
        return mods
    }

    static func unshiftedCodepoint(_ event: NSEvent) -> UInt32 {
        guard let chars = event.charactersIgnoringModifiers, let ch = chars.unicodeScalars.first else {
            return 0
        }
        let v = ch.value
        if (0x41...0x5A).contains(v) { return v + 32 }
        return v
    }

    static func mapKey(_ event: NSEvent) -> GhosttyKey {
        if let chars = event.charactersIgnoringModifiers?.lowercased(), let c = chars.first {
            switch c {
            case "a": return GHOSTTY_KEY_A
            case "b": return GHOSTTY_KEY_B
            case "c": return GHOSTTY_KEY_C
            case "d": return GHOSTTY_KEY_D
            case "e": return GHOSTTY_KEY_E
            case "f": return GHOSTTY_KEY_F
            case "g": return GHOSTTY_KEY_G
            case "h": return GHOSTTY_KEY_H
            case "i": return GHOSTTY_KEY_I
            case "j": return GHOSTTY_KEY_J
            case "k": return GHOSTTY_KEY_K
            case "l": return GHOSTTY_KEY_L
            case "m": return GHOSTTY_KEY_M
            case "n": return GHOSTTY_KEY_N
            case "o": return GHOSTTY_KEY_O
            case "p": return GHOSTTY_KEY_P
            case "q": return GHOSTTY_KEY_Q
            case "r": return GHOSTTY_KEY_R
            case "s": return GHOSTTY_KEY_S
            case "t": return GHOSTTY_KEY_T
            case "u": return GHOSTTY_KEY_U
            case "v": return GHOSTTY_KEY_V
            case "w": return GHOSTTY_KEY_W
            case "x": return GHOSTTY_KEY_X
            case "y": return GHOSTTY_KEY_Y
            case "z": return GHOSTTY_KEY_Z
            case "0": return GHOSTTY_KEY_DIGIT_0
            case "1": return GHOSTTY_KEY_DIGIT_1
            case "2": return GHOSTTY_KEY_DIGIT_2
            case "3": return GHOSTTY_KEY_DIGIT_3
            case "4": return GHOSTTY_KEY_DIGIT_4
            case "5": return GHOSTTY_KEY_DIGIT_5
            case "6": return GHOSTTY_KEY_DIGIT_6
            case "7": return GHOSTTY_KEY_DIGIT_7
            case "8": return GHOSTTY_KEY_DIGIT_8
            case "9": return GHOSTTY_KEY_DIGIT_9
            case " ": return GHOSTTY_KEY_SPACE
            case "-": return GHOSTTY_KEY_MINUS
            case "=": return GHOSTTY_KEY_EQUAL
            case "[": return GHOSTTY_KEY_BRACKET_LEFT
            case "]": return GHOSTTY_KEY_BRACKET_RIGHT
            case "\\": return GHOSTTY_KEY_BACKSLASH
            case ";": return GHOSTTY_KEY_SEMICOLON
            case "'": return GHOSTTY_KEY_QUOTE
            case ",": return GHOSTTY_KEY_COMMA
            case ".": return GHOSTTY_KEY_PERIOD
            case "/": return GHOSTTY_KEY_SLASH
            case "`": return GHOSTTY_KEY_BACKQUOTE
            default: break
            }
        }

        switch event.keyCode {
        case 36: return GHOSTTY_KEY_ENTER
        case 48: return GHOSTTY_KEY_TAB
        case 51: return GHOSTTY_KEY_BACKSPACE
        case 53: return GHOSTTY_KEY_ESCAPE
        case 117: return GHOSTTY_KEY_DELETE
        case 123: return GHOSTTY_KEY_ARROW_LEFT
        case 124: return GHOSTTY_KEY_ARROW_RIGHT
        case 125: return GHOSTTY_KEY_ARROW_DOWN
        case 126: return GHOSTTY_KEY_ARROW_UP
        case 115: return GHOSTTY_KEY_HOME
        case 119: return GHOSTTY_KEY_END
        case 116: return GHOSTTY_KEY_PAGE_UP
        case 121: return GHOSTTY_KEY_PAGE_DOWN
        case 114: return GHOSTTY_KEY_INSERT
        case 122: return GHOSTTY_KEY_F1
        case 120: return GHOSTTY_KEY_F2
        case 99: return GHOSTTY_KEY_F3
        case 118: return GHOSTTY_KEY_F4
        case 96: return GHOSTTY_KEY_F5
        case 97: return GHOSTTY_KEY_F6
        case 98: return GHOSTTY_KEY_F7
        case 100: return GHOSTTY_KEY_F8
        case 101: return GHOSTTY_KEY_F9
        case 109: return GHOSTTY_KEY_F10
        case 103: return GHOSTTY_KEY_F11
        case 111: return GHOSTTY_KEY_F12
        default: return GHOSTTY_KEY_UNIDENTIFIED
        }
    }
}
