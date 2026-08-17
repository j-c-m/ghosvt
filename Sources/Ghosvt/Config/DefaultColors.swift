import CGhosttyVT

/// Hardcoded host defaults: Eighties Black (`terminal-themes` eighties-black).
///
/// Cursor is cell-foreground / cell-background (no absolute COLOR_CURSOR).
enum DefaultColors {
    static let foreground = GhosttyColorRgb(r: 0xCC, g: 0xCC, b: 0xCC)
    static let background = GhosttyColorRgb(r: 0x00, g: 0x00, b: 0x00)

    /// ANSI 0–15 from Eighties Black. Rest of the 256-color cube stays libghostty default.
    static let ansi16: [GhosttyColorRgb] = [
        GhosttyColorRgb(r: 0x11, g: 0x11, b: 0x11), // 0
        GhosttyColorRgb(r: 0xEE, g: 0x45, b: 0x49), // 1
        GhosttyColorRgb(r: 0x59, g: 0xB2, b: 0x59), // 2
        GhosttyColorRgb(r: 0xC8, g: 0x61, b: 0x31), // 3
        GhosttyColorRgb(r: 0x37, g: 0x73, b: 0xAF), // 4
        GhosttyColorRgb(r: 0xB2, g: 0x59, b: 0xB2), // 5
        GhosttyColorRgb(r: 0x37, g: 0xAF, b: 0xAF), // 6
        GhosttyColorRgb(r: 0xCC, g: 0xCC, b: 0xCC), // 7
        GhosttyColorRgb(r: 0x88, g: 0x88, b: 0x88), // 8
        GhosttyColorRgb(r: 0xF2, g: 0x77, b: 0x7A), // 9
        GhosttyColorRgb(r: 0x99, g: 0xCC, b: 0x99), // 10
        GhosttyColorRgb(r: 0xFF, g: 0xCC, b: 0x66), // 11
        GhosttyColorRgb(r: 0x66, g: 0x99, b: 0xCC), // 12
        GhosttyColorRgb(r: 0xCC, g: 0x99, b: 0xCC), // 13
        GhosttyColorRgb(r: 0x66, g: 0xCC, b: 0xCC), // 14
        GhosttyColorRgb(r: 0xF2, g: 0xF0, b: 0xEC), // 15
    ]

    /// Install fg/bg + palette from the resolved theme. Does not set an absolute
    /// cursor color; `cursor-color` / `cursor-text` are paint-time.
    static func apply(to terminal: GhosttyTerminal, theme: ResolvedTheme = Theme.current) {
        var fg = theme.foreground
        var bg = theme.background
        withUnsafePointer(to: &fg) { ptr in
            _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, UnsafeRawPointer(ptr))
        }
        withUnsafePointer(to: &bg) { ptr in
            _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, UnsafeRawPointer(ptr))
        }

        var palette = theme.palette
        if palette.count < 256 {
            palette.append(contentsOf: repeatElement(
                GhosttyColorRgb(r: 0, g: 0, b: 0),
                count: 256 - palette.count
            ))
        }
        palette.withUnsafeMutableBufferPointer { buf in
            var stock = [GhosttyColorRgb](repeating: GhosttyColorRgb(r: 0, g: 0, b: 0), count: 256)
            _ = stock.withUnsafeMutableBufferPointer { sbuf in
                ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT, sbuf.baseAddress)
            }
            for i in 16..<256 where i < buf.count {
                if buf[i].r == 0, buf[i].g == 0, buf[i].b == 0 {
                    buf[i] = stock[i]
                }
            }
        }
        _ = palette.withUnsafeBufferPointer { buf in
            ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, UnsafeRawPointer(buf.baseAddress))
        }
    }
}
