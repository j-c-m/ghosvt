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
            // Ghostty `scroll-to-bottom = keystroke` (default on).
            if session.scrollToBottomKeystroke {
                session.scrollViewportToBottom()
            }
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

    /// Modifiers treated as consumed for text translation (Ghostty heuristic).
    /// Control and Command never contribute to character translation.
    static func consumedMods(for event: NSEvent) -> GhosttyMods {
        let translation = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.control, .command])
        return mapMods(translation)
    }

    /// Unshifted codepoint via `byApplyingModifiers: []` (not `charactersIgnoringModifiers`,
    /// which changes under Ctrl).
    static func unshiftedCodepoint(_ event: NSEvent) -> UInt32 {
        guard event.type == .keyDown || event.type == .keyUp else { return 0 }
        guard let chars = event.characters(byApplyingModifiers: []),
              let scalar = chars.unicodeScalars.first
        else { return 0 }
        let v = scalar.value
        // Never feed macOS function-key PUA into the encoder.
        if v >= 0xF700, v <= 0xF8FF { return 0 }
        return v
    }

    /// Text for the key encoder / printable short-circuit.
    /// Drops C0 controls and macOS function-key PUA (U+F700…U+F8FF).
    static func encoderText(for event: NSEvent) -> String? {
        guard let characters = event.characters, !characters.isEmpty else { return nil }

        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            let v = scalar.value
            // Control chars: encoder owns Ctrl mapping; do not pass C0 as text.
            if v < 0x20 || v == 0x7F { return nil }
            // AppKit arrows/home/F-keys land in the Private Use Area.
            if v >= 0xF700, v <= 0xF8FF { return nil }
        } else {
            // Multi-scalar: drop if any PUA (rare; be safe).
            if characters.unicodeScalars.contains(where: { $0.value >= 0xF700 && $0.value <= 0xF8FF }) {
                return nil
            }
        }
        return characters
    }

    /// True for keys that must go through the CSI/function-key encoder path.
    static func requiresEncoder(_ key: GhosttyKey) -> Bool {
        switch key {
        case GHOSTTY_KEY_ARROW_UP, GHOSTTY_KEY_ARROW_DOWN,
             GHOSTTY_KEY_ARROW_LEFT, GHOSTTY_KEY_ARROW_RIGHT,
             GHOSTTY_KEY_HOME, GHOSTTY_KEY_END,
             GHOSTTY_KEY_PAGE_UP, GHOSTTY_KEY_PAGE_DOWN,
             GHOSTTY_KEY_INSERT, GHOSTTY_KEY_DELETE,
             GHOSTTY_KEY_ESCAPE, GHOSTTY_KEY_TAB, GHOSTTY_KEY_ENTER,
             GHOSTTY_KEY_BACKSPACE,
             GHOSTTY_KEY_F1, GHOSTTY_KEY_F2, GHOSTTY_KEY_F3, GHOSTTY_KEY_F4,
             GHOSTTY_KEY_F5, GHOSTTY_KEY_F6, GHOSTTY_KEY_F7, GHOSTTY_KEY_F8,
             GHOSTTY_KEY_F9, GHOSTTY_KEY_F10, GHOSTTY_KEY_F11, GHOSTTY_KEY_F12,
             GHOSTTY_KEY_F13, GHOSTTY_KEY_F14, GHOSTTY_KEY_F15, GHOSTTY_KEY_F16,
             GHOSTTY_KEY_F17, GHOSTTY_KEY_F18, GHOSTTY_KEY_F19, GHOSTTY_KEY_F20,
             GHOSTTY_KEY_NUMPAD_ENTER, GHOSTTY_KEY_NUMPAD_UP, GHOSTTY_KEY_NUMPAD_DOWN,
             GHOSTTY_KEY_NUMPAD_LEFT, GHOSTTY_KEY_NUMPAD_RIGHT,
             GHOSTTY_KEY_NUMPAD_HOME, GHOSTTY_KEY_NUMPAD_END,
             GHOSTTY_KEY_NUMPAD_PAGE_UP, GHOSTTY_KEY_NUMPAD_PAGE_DOWN,
             GHOSTTY_KEY_NUMPAD_INSERT, GHOSTTY_KEY_NUMPAD_DELETE,
             GHOSTTY_KEY_NUMPAD_BEGIN:
            return true
        default:
            return false
        }
    }

    /// Hard fallback CSI sequences when the encoder returns empty.
    /// Normal (not application) cursor mode — encoder prefers DECCKM when set.
    static func legacySequence(for key: GhosttyKey, mods: GhosttyMods) -> [UInt8]? {
        let shift = (mods & GhosttyMods(GHOSTTY_MODS_SHIFT)) != 0
        let ctrl = (mods & GhosttyMods(GHOSTTY_MODS_CTRL)) != 0
        let alt = (mods & GhosttyMods(GHOSTTY_MODS_ALT)) != 0
        let modBits = (shift ? 1 : 0) | (alt ? 2 : 0) | (ctrl ? 4 : 0)
        // xterm modifier param = 1 + bitfield; only emit when non-zero.
        let modParam = modBits == 0 ? nil : modBits + 1

        func csi(_ body: String) -> [UInt8] {
            Array(("\u{1b}[" + body).utf8)
        }
        func ss3(_ ch: Character) -> [UInt8] {
            Array(("\u{1b}O" + String(ch)).utf8)
        }
        func csiTilde(_ n: Int) -> [UInt8] {
            if let m = modParam {
                return csi("\(n);\(m)~")
            }
            return csi("\(n)~")
        }
        func csiLetter(_ letter: Character) -> [UInt8] {
            if let m = modParam {
                return csi("1;\(m)" + String(letter))
            }
            return csi(String(letter))
        }

        switch key {
        case GHOSTTY_KEY_ARROW_UP: return csiLetter("A")
        case GHOSTTY_KEY_ARROW_DOWN: return csiLetter("B")
        case GHOSTTY_KEY_ARROW_RIGHT: return csiLetter("C")
        case GHOSTTY_KEY_ARROW_LEFT: return csiLetter("D")
        case GHOSTTY_KEY_HOME: return csiLetter("H")
        case GHOSTTY_KEY_END: return csiLetter("F")
        case GHOSTTY_KEY_INSERT: return csiTilde(2)
        case GHOSTTY_KEY_DELETE: return csiTilde(3)
        case GHOSTTY_KEY_PAGE_UP: return csiTilde(5)
        case GHOSTTY_KEY_PAGE_DOWN: return csiTilde(6)
        case GHOSTTY_KEY_F1: return modParam == nil ? ss3("P") : csi("1;\(modParam!)P")
        case GHOSTTY_KEY_F2: return modParam == nil ? ss3("Q") : csi("1;\(modParam!)Q")
        case GHOSTTY_KEY_F3: return modParam == nil ? ss3("R") : csi("1;\(modParam!)R")
        case GHOSTTY_KEY_F4: return modParam == nil ? ss3("S") : csi("1;\(modParam!)S")
        case GHOSTTY_KEY_F5: return csiTilde(15)
        case GHOSTTY_KEY_F6: return csiTilde(17)
        case GHOSTTY_KEY_F7: return csiTilde(18)
        case GHOSTTY_KEY_F8: return csiTilde(19)
        case GHOSTTY_KEY_F9: return csiTilde(20)
        case GHOSTTY_KEY_F10: return csiTilde(21)
        case GHOSTTY_KEY_F11: return csiTilde(23)
        case GHOSTTY_KEY_F12: return csiTilde(24)
        case GHOSTTY_KEY_ESCAPE: return [0x1B]
        case GHOSTTY_KEY_TAB:
            if shift { return [0x1B, 0x5B, 0x5A] } // CSI Z
            return [0x09]
        case GHOSTTY_KEY_ENTER, GHOSTTY_KEY_NUMPAD_ENTER: return [0x0D]
        case GHOSTTY_KEY_BACKSPACE: return [0x7F]
        case GHOSTTY_KEY_SPACE: return [0x20]
        default: return nil
        }
    }

    /// Map AppKit hardware keyCode → Ghostty logical key (W3C codes).
    /// Prefer keyCode over `characters` so arrows/numpad/F-keys never depend on PUA text.
    static func mapKey(_ event: NSEvent) -> GhosttyKey {
        if let key = keyFromKeyCode(event.keyCode) {
            return key
        }
        // Layout fallback for unusual ISO keys.
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
        return GHOSTTY_KEY_UNIDENTIFIED
    }

    /// Carbon/HIToolbox virtual key codes → GhosttyKey (aligned with Ghostty macOS).
    private static func keyFromKeyCode(_ keyCode: UInt16) -> GhosttyKey? {
        switch keyCode {
        // Letters
        case 0x00: return GHOSTTY_KEY_A
        case 0x0B: return GHOSTTY_KEY_B
        case 0x08: return GHOSTTY_KEY_C
        case 0x02: return GHOSTTY_KEY_D
        case 0x0E: return GHOSTTY_KEY_E
        case 0x03: return GHOSTTY_KEY_F
        case 0x05: return GHOSTTY_KEY_G
        case 0x04: return GHOSTTY_KEY_H
        case 0x22: return GHOSTTY_KEY_I
        case 0x26: return GHOSTTY_KEY_J
        case 0x28: return GHOSTTY_KEY_K
        case 0x25: return GHOSTTY_KEY_L
        case 0x2E: return GHOSTTY_KEY_M
        case 0x2D: return GHOSTTY_KEY_N
        case 0x1F: return GHOSTTY_KEY_O
        case 0x23: return GHOSTTY_KEY_P
        case 0x0C: return GHOSTTY_KEY_Q
        case 0x0F: return GHOSTTY_KEY_R
        case 0x01: return GHOSTTY_KEY_S
        case 0x11: return GHOSTTY_KEY_T
        case 0x20: return GHOSTTY_KEY_U
        case 0x09: return GHOSTTY_KEY_V
        case 0x0D: return GHOSTTY_KEY_W
        case 0x07: return GHOSTTY_KEY_X
        case 0x10: return GHOSTTY_KEY_Y
        case 0x06: return GHOSTTY_KEY_Z

        // Digits (main)
        case 0x1D: return GHOSTTY_KEY_DIGIT_0
        case 0x12: return GHOSTTY_KEY_DIGIT_1
        case 0x13: return GHOSTTY_KEY_DIGIT_2
        case 0x14: return GHOSTTY_KEY_DIGIT_3
        case 0x15: return GHOSTTY_KEY_DIGIT_4
        case 0x17: return GHOSTTY_KEY_DIGIT_5
        case 0x16: return GHOSTTY_KEY_DIGIT_6
        case 0x1A: return GHOSTTY_KEY_DIGIT_7
        case 0x1C: return GHOSTTY_KEY_DIGIT_8
        case 0x19: return GHOSTTY_KEY_DIGIT_9

        // Punctuation / writing system
        case 0x32: return GHOSTTY_KEY_BACKQUOTE
        case 0x1B: return GHOSTTY_KEY_MINUS
        case 0x18: return GHOSTTY_KEY_EQUAL
        case 0x21: return GHOSTTY_KEY_BRACKET_LEFT
        case 0x1E: return GHOSTTY_KEY_BRACKET_RIGHT
        case 0x2A: return GHOSTTY_KEY_BACKSLASH
        case 0x29: return GHOSTTY_KEY_SEMICOLON
        case 0x27: return GHOSTTY_KEY_QUOTE
        case 0x2B: return GHOSTTY_KEY_COMMA
        case 0x2F: return GHOSTTY_KEY_PERIOD
        case 0x2C: return GHOSTTY_KEY_SLASH
        case 0x0A: return GHOSTTY_KEY_INTL_BACKSLASH
        case 0x5E: return GHOSTTY_KEY_INTL_RO
        case 0x5D: return GHOSTTY_KEY_INTL_YEN

        // Functional
        case 0x31: return GHOSTTY_KEY_SPACE
        case 0x30: return GHOSTTY_KEY_TAB
        case 0x24: return GHOSTTY_KEY_ENTER
        case 0x33: return GHOSTTY_KEY_BACKSPACE
        case 0x35: return GHOSTTY_KEY_ESCAPE
        case 0x39: return GHOSTTY_KEY_CAPS_LOCK
        case 0x3A: return GHOSTTY_KEY_ALT_LEFT
        case 0x3D: return GHOSTTY_KEY_ALT_RIGHT
        case 0x3B: return GHOSTTY_KEY_CONTROL_LEFT
        case 0x3E: return GHOSTTY_KEY_CONTROL_RIGHT
        case 0x38: return GHOSTTY_KEY_SHIFT_LEFT
        case 0x3C: return GHOSTTY_KEY_SHIFT_RIGHT
        case 0x37: return GHOSTTY_KEY_META_LEFT
        case 0x36: return GHOSTTY_KEY_META_RIGHT
        case 0x6E: return GHOSTTY_KEY_CONTEXT_MENU

        // Control pad
        case 0x75: return GHOSTTY_KEY_DELETE
        case 0x73: return GHOSTTY_KEY_HOME
        case 0x77: return GHOSTTY_KEY_END
        case 0x74: return GHOSTTY_KEY_PAGE_UP
        case 0x79: return GHOSTTY_KEY_PAGE_DOWN
        case 0x72: return GHOSTTY_KEY_INSERT

        // Arrows
        case 0x7B: return GHOSTTY_KEY_ARROW_LEFT
        case 0x7C: return GHOSTTY_KEY_ARROW_RIGHT
        case 0x7D: return GHOSTTY_KEY_ARROW_DOWN
        case 0x7E: return GHOSTTY_KEY_ARROW_UP

        // Numpad
        case 0x47: return GHOSTTY_KEY_NUM_LOCK
        case 0x52: return GHOSTTY_KEY_NUMPAD_0
        case 0x53: return GHOSTTY_KEY_NUMPAD_1
        case 0x54: return GHOSTTY_KEY_NUMPAD_2
        case 0x55: return GHOSTTY_KEY_NUMPAD_3
        case 0x56: return GHOSTTY_KEY_NUMPAD_4
        case 0x57: return GHOSTTY_KEY_NUMPAD_5
        case 0x58: return GHOSTTY_KEY_NUMPAD_6
        case 0x59: return GHOSTTY_KEY_NUMPAD_7
        case 0x5B: return GHOSTTY_KEY_NUMPAD_8
        case 0x5C: return GHOSTTY_KEY_NUMPAD_9
        case 0x45: return GHOSTTY_KEY_NUMPAD_ADD
        case 0x4E: return GHOSTTY_KEY_NUMPAD_SUBTRACT
        case 0x43: return GHOSTTY_KEY_NUMPAD_MULTIPLY
        case 0x4B: return GHOSTTY_KEY_NUMPAD_DIVIDE
        case 0x41: return GHOSTTY_KEY_NUMPAD_DECIMAL
        case 0x4C: return GHOSTTY_KEY_NUMPAD_ENTER
        case 0x51: return GHOSTTY_KEY_NUMPAD_EQUAL
        case 0x5F: return GHOSTTY_KEY_NUMPAD_COMMA

        // Function keys
        case 0x7A: return GHOSTTY_KEY_F1
        case 0x78: return GHOSTTY_KEY_F2
        case 0x63: return GHOSTTY_KEY_F3
        case 0x76: return GHOSTTY_KEY_F4
        case 0x60: return GHOSTTY_KEY_F5
        case 0x61: return GHOSTTY_KEY_F6
        case 0x62: return GHOSTTY_KEY_F7
        case 0x64: return GHOSTTY_KEY_F8
        case 0x65: return GHOSTTY_KEY_F9
        case 0x6D: return GHOSTTY_KEY_F10
        case 0x67: return GHOSTTY_KEY_F11
        case 0x6F: return GHOSTTY_KEY_F12
        case 0x69: return GHOSTTY_KEY_F13
        case 0x6B: return GHOSTTY_KEY_F14
        case 0x71: return GHOSTTY_KEY_F15
        case 0x6A: return GHOSTTY_KEY_F16
        case 0x40: return GHOSTTY_KEY_F17
        case 0x4F: return GHOSTTY_KEY_F18
        case 0x50: return GHOSTTY_KEY_F19
        case 0x5A: return GHOSTTY_KEY_F20

        default: return nil
        }
    }
}
