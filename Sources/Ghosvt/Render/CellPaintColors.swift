import CGhosttyVT
import Foundation

/// Single policy for cell fill / ink colors (including selection invert).
///
/// Matches Ghostty defaults:
/// - selection-background = cell-foreground
/// - selection-foreground = cell-background
enum CellPaintColors {
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

        func faint(_ on: Bool) -> RGB {
            guard on else { return self }
            return RGB(r: r * 0.5, g: g * 0.5, b: b * 0.5)
        }
    }

    /// Fill (background) and ink (foreground) for a cell after optional selection.
    static func pair(
        fg: GhosttyColorRgb,
        bg: GhosttyColorRgb,
        faint: Bool,
        selected: Bool
    ) -> (fill: RGB, ink: RGB) {
        var ink = RGB(fg).faint(faint)
        var fill = RGB(bg)
        if selected {
            swap(&ink, &fill)
        }
        return (fill, ink)
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
