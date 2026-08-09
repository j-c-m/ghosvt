import CGhosttyVT

/// Hardcoded host defaults: Spacegray Eighties with overrides.
///
/// Overrides on stock Spacegray Eighties:
/// - background = #000000
/// - foreground = #cccccc
/// - palette 3 = #d3a03e
/// - palette 8 = #888888
/// - cursor defaults to cell-foreground / cell-background (no absolute COLOR_CURSOR)
enum DefaultColors {
    static let foreground = GhosttyColorRgb(r: 0xCC, g: 0xCC, b: 0xCC)
    static let background = GhosttyColorRgb(r: 0x00, g: 0x00, b: 0x00)

    /// ANSI 0–15: Spacegray Eighties with palette 3/8 overrides.
    /// Rest of the 256-color cube stays libghostty default.
    static let ansi16: [GhosttyColorRgb] = [
        GhosttyColorRgb(r: 0x15, g: 0x17, b: 0x1C), // 0
        GhosttyColorRgb(r: 0xEC, g: 0x5F, b: 0x67), // 1
        GhosttyColorRgb(r: 0x81, g: 0xA7, b: 0x64), // 2
        GhosttyColorRgb(r: 0xD3, g: 0xA0, b: 0x3E), // 3 override
        GhosttyColorRgb(r: 0x54, g: 0x86, b: 0xC0), // 4
        GhosttyColorRgb(r: 0xBF, g: 0x83, b: 0xC1), // 5
        GhosttyColorRgb(r: 0x57, g: 0xC2, b: 0xC1), // 6
        GhosttyColorRgb(r: 0xEF, g: 0xEC, b: 0xE7), // 7
        GhosttyColorRgb(r: 0x88, g: 0x88, b: 0x88), // 8 override
        GhosttyColorRgb(r: 0xFF, g: 0x69, b: 0x73), // 9
        GhosttyColorRgb(r: 0x93, g: 0xD4, b: 0x93), // 10
        GhosttyColorRgb(r: 0xFF, g: 0xD2, b: 0x56), // 11
        GhosttyColorRgb(r: 0x4D, g: 0x84, b: 0xD1), // 12
        GhosttyColorRgb(r: 0xFF, g: 0x55, b: 0xFF), // 13
        GhosttyColorRgb(r: 0x83, g: 0xE9, b: 0xE4), // 14
        GhosttyColorRgb(r: 0xFF, g: 0xFF, b: 0xFF), // 15
    ]

    /// Install fg/bg + ANSI 0–15. Does not set an absolute cursor color so the
    /// host default is Ghostty `cursor-color = cell-foreground` /
    /// `cursor-text = cell-background` (OSC 12 can still set a fixed cursor).
    static func apply(to terminal: GhosttyTerminal) {
        var fg = foreground
        var bg = background
        withUnsafePointer(to: &fg) { ptr in
            _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, UnsafeRawPointer(ptr))
        }
        withUnsafePointer(to: &bg) { ptr in
            _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, UnsafeRawPointer(ptr))
        }

        // Start from libghostty’s full 256 palette, then overlay ANSI 0–15.
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
