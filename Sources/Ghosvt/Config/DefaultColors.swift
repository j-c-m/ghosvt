import CGhosttyVT

/// Hardcoded host defaults: IBM 5153 CGA Black (int10h true CGA).
/// Source: terminal-themes build/ghostty/ibm-5153-cga-black
enum DefaultColors {
    static let foreground = GhosttyColorRgb(r: 0xC4, g: 0xC4, b: 0xC4)
    static let background = GhosttyColorRgb(r: 0x00, g: 0x00, b: 0x00)
    static let cursor = GhosttyColorRgb(r: 0xC4, g: 0xC4, b: 0xC4)

    /// ANSI 0–15 only; rest of the 256-color cube stays libghostty default.
    static let ansi16: [GhosttyColorRgb] = [
        GhosttyColorRgb(r: 0x00, g: 0x00, b: 0x00), // 0 black
        GhosttyColorRgb(r: 0xC4, g: 0x00, b: 0x00), // 1 red
        GhosttyColorRgb(r: 0x00, g: 0xC4, b: 0x00), // 2 green
        GhosttyColorRgb(r: 0xC4, g: 0x7E, b: 0x00), // 3 yellow/brown
        GhosttyColorRgb(r: 0x00, g: 0x00, b: 0xC4), // 4 blue
        GhosttyColorRgb(r: 0xC4, g: 0x00, b: 0xC4), // 5 magenta
        GhosttyColorRgb(r: 0x00, g: 0xC4, b: 0xC4), // 6 cyan
        GhosttyColorRgb(r: 0xC4, g: 0xC4, b: 0xC4), // 7 white
        GhosttyColorRgb(r: 0x4E, g: 0x4E, b: 0x4E), // 8 bright black
        GhosttyColorRgb(r: 0xDC, g: 0x4E, b: 0x4E), // 9 bright red
        GhosttyColorRgb(r: 0x4E, g: 0xDC, b: 0x4E), // 10 bright green
        GhosttyColorRgb(r: 0xF3, g: 0xF3, b: 0x4E), // 11 bright yellow
        GhosttyColorRgb(r: 0x4E, g: 0x4E, b: 0xDC), // 12 bright blue
        GhosttyColorRgb(r: 0xF3, g: 0x4E, b: 0xF3), // 13 bright magenta
        GhosttyColorRgb(r: 0x4E, g: 0xF3, b: 0xF3), // 14 bright cyan
        GhosttyColorRgb(r: 0xFF, g: 0xFF, b: 0xFF), // 15 bright white
    ]

    /// Install fg/bg/cursor + ANSI 0–15 on a new terminal.
    static func apply(to terminal: GhosttyTerminal) {
        var fg = foreground
        var bg = background
        var cur = cursor
        withUnsafePointer(to: &fg) { ptr in
            _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, UnsafeRawPointer(ptr))
        }
        withUnsafePointer(to: &bg) { ptr in
            _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, UnsafeRawPointer(ptr))
        }
        withUnsafePointer(to: &cur) { ptr in
            _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, UnsafeRawPointer(ptr))
        }

        // Start from libghostty’s full 256 palette, then overlay CGA ANSI 0–15.
        var palette = [GhosttyColorRgb](repeating: GhosttyColorRgb(r: 0, g: 0, b: 0), count: 256)
        _ = palette.withUnsafeMutableBufferPointer { buf in
            ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT, buf.baseAddress)
        }
        for i in 0..<min(16, ansi16.count) {
            palette[i] = ansi16[i]
        }
        _ = palette.withUnsafeBufferPointer { buf in
            ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, UnsafeRawPointer(buf.baseAddress))
        }
    }
}
