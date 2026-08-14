import CGhosttyVT
import Foundation

/// Single policy for cell fill / ink colors (selection invert + search highlights).
///
/// Matches Ghostty defaults:
/// - selection-background = cell-foreground / selection-foreground = cell-background
/// - search-background = #FFE082, search-foreground = black
/// - search-selected-background = #F2A57E, search-selected-foreground = black
enum CellPaintColors {
    /// Paint-time highlight precedence (highest first): selection → searchSelected → search.
    enum Highlight: Equatable {
        case none
        case selection
        case search
        case searchSelected
    }

    struct RGB {
        var r: Float
        var g: Float
        var b: Float

        init(_ c: GhosttyColorRgb) {
            r = Float(c.r) / 255
            g = Float(c.g) / 255
            b = Float(c.b) / 255
        }

        init(r: Float, g: Float, b: Float) {
            self.r = r
            self.g = g
            self.b = b
        }

        init(byteR: UInt8, g byteG: UInt8, b byteB: UInt8) {
            r = Float(byteR) / 255
            g = Float(byteG) / 255
            b = Float(byteB) / 255
        }

        func faint(_ on: Bool) -> RGB {
            guard on else { return self }
            return RGB(r: r * 0.5, g: g * 0.5, b: b * 0.5)
        }
    }

    /// Ghostty `search-background` / `search-foreground`.
    static let searchFill = RGB(byteR: 0xFF, g: 0xE0, b: 0x82)
    static let searchInk = RGB(byteR: 0x00, g: 0x00, b: 0x00)
    /// Ghostty `search-selected-background` / `search-selected-foreground`.
    static let searchSelectedFill = RGB(byteR: 0xF2, g: 0xA5, b: 0x7E)
    static let searchSelectedInk = RGB(byteR: 0x00, g: 0x00, b: 0x00)

    /// Fill (background) and ink (foreground) for a cell after highlight.
    static func pair(
        fg: GhosttyColorRgb,
        bg: GhosttyColorRgb,
        faint: Bool,
        selected: Bool
    ) -> (fill: RGB, ink: RGB) {
        pair(fg: fg, bg: bg, faint: faint, highlight: selected ? .selection : .none)
    }

    static func pair(
        fg: GhosttyColorRgb,
        bg: GhosttyColorRgb,
        faint: Bool,
        highlight: Highlight
    ) -> (fill: RGB, ink: RGB) {
        let baseInk = RGB(fg).faint(faint)
        let baseFill = RGB(bg)
        switch highlight {
        case .none:
            return (baseFill, baseInk)
        case .selection:
            // Ghostty default: invert cell fg/bg.
            return (baseInk, baseFill)
        case .search:
            return (searchFill, searchInk)
        case .searchSelected:
            return (searchSelectedFill, searchSelectedInk)
        }
    }

    /// Cursor fill / text for host defaults `cell-foreground` / `cell-background`.
    /// OSC 12 absolute cursor color overrides fill only when provided.
    static func cursor(
        cellInk: RGB,
        cellFill: RGB,
        defFg: GhosttyColorRgb,
        oscCursor: GhosttyColorRgb?
    ) -> (fill: RGB, text: RGB) {
        var fill = cellInk
        // Empty / no distinct ink → theme foreground.
        if fill.r == 0, fill.g == 0, fill.b == 0 {
            fill = RGB(defFg)
        }
        let text = cellFill
        if let osc = oscCursor {
            fill = RGB(osc)
        }
        return (fill, text)
    }
}

/// One viewport cell after VT collect (shared by paint + cursor).
struct TerminalRowCell {
    var text: String
    /// First scalar, or 0 if empty. Shaper hash treats 0 as U+0020.
    var cp: UInt32 = 0
    var isWideHead: Bool
    var isWideTail: Bool
    var fg: GhosttyColorRgb
    var bg: GhosttyColorRgb
    var bold: Bool
    var italic: Bool
    var faint: Bool
    var inverse: Bool
    var underline: Bool

    var isSpaceOrEmpty: Bool {
        if isWideHead || isWideTail { return false }
        if text.isEmpty { return true }
        return text == " " || text == "\u{00A0}"
    }

    var textStyle: TextStyleKey {
        TextStyleKey(
            fr: fg.r, fg: fg.g, fb: fg.b,
            bold: bold, italic: italic, faint: faint,
            inverse: inverse, underline: underline
        )
    }
}
