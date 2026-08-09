import CoreText

struct CellMetrics {
    /// Cell size in view points (for AppKit layout / hit testing).
    var cellWidth: CGFloat
    var cellHeight: CGFloat
    /// Cell size in **device pixels** (1:1 atlas ↔ framebuffer).
    var cellWidthPx: Int
    var cellHeightPx: Int
    /// Distance from the **bottom** of the cell to the text baseline (device px).
    /// Matches Ghostty `Metrics.cell_baseline`.
    var cellBaselinePx: Int
    /// Unrounded face advance width (device px), used to center ink in the cell.
    var faceWidthPx: CGFloat
    var fontSize: CGFloat
    /// Font size in device pixels (CT size).
    var fontPx: Int
    var font: CTFont
    var fontBold: CTFont
    var fontItalic: CTFont
    var fontBoldItalic: CTFont
    /// Ascent in points.
    var ascent: CGFloat

    static func measure(fontSize: CGFloat, scale: CGFloat) -> CellMetrics {
        let s = max(scale, 0.5)
        // Font size in device pixels so CT raster matches drawable pixels 1:1.
        let pxSize = fontSize * s
        let fontPx = max(1, Int(pxSize.rounded()))

        let regular = EmbeddedFonts.primary(size: pxSize, bold: false, italic: false)
        let bold = EmbeddedFonts.primary(size: pxSize, bold: true, italic: false)
        let italic = EmbeddedFonts.primary(size: pxSize, bold: false, italic: true)
        let boldItalic = EmbeddedFonts.primary(size: pxSize, bold: true, italic: true)

        // Ghostty face_width: max horizontal advance of visible ASCII (32…126),
        // not only 'M' — some monospaced faces still vary slightly.
        var faceWidth: CGFloat = 0
        for code in 32...126 {
            var ch = UniChar(code)
            var g = CGGlyph()
            guard CTFontGetGlyphsForCharacters(regular, &ch, &g, 1), g != 0 else { continue }
            var adv = CGSize.zero
            CTFontGetAdvancesForGlyphs(regular, .horizontal, &g, &adv, 1)
            faceWidth = max(faceWidth, adv.width)
        }
        if faceWidth < 0.5 {
            var ch: UniChar = 0x004D
            var g = CGGlyph()
            CTFontGetGlyphsForCharacters(regular, &ch, &g, 1)
            var adv = CGSize.zero
            CTFontGetAdvancesForGlyphs(regular, .horizontal, &g, &adv, 1)
            faceWidth = adv.width
        }

        // CT: ascent/descent/leading are all non-negative (descent is magnitude).
        let ascent = CTFontGetAscent(regular)
        let descent = CTFontGetDescent(regular)
        let leading = CTFontGetLeading(regular)

        // Ghostty Metrics.calc (with CT-positive descent):
        //   face_height = ascent + descent + leading
        //   cell_* = round(face_*)
        //   half_line_gap on top and bottom; baseline centered in the rounded cell.
        let faceHeight = ascent + descent + leading
        // Default matches Ghostty `adjust-cell-width = 1` (+1 device px).
        let cellWPx = max(1, Int(faceWidth.rounded()) + 1)
        let cellHPx = max(1, Int(faceHeight.rounded()))

        let halfLineGap = leading / 2
        let faceBaseline = halfLineGap + descent // from bottom of face box
        let cellBaseline = max(
            0,
            Int((faceBaseline - (CGFloat(cellHPx) - faceHeight) / 2).rounded())
        )

        return CellMetrics(
            cellWidth: CGFloat(cellWPx) / s,
            cellHeight: CGFloat(cellHPx) / s,
            cellWidthPx: cellWPx,
            cellHeightPx: cellHPx,
            cellBaselinePx: min(cellBaseline, cellHPx),
            faceWidthPx: faceWidth,
            fontSize: fontSize,
            fontPx: fontPx,
            font: regular,
            fontBold: bold,
            fontItalic: italic,
            fontBoldItalic: boldItalic,
            ascent: ascent / s
        )
    }

    func font(bold: Bool, italic: Bool) -> CTFont {
        switch (bold, italic) {
        case (true, true): return fontBoldItalic
        case (true, false): return fontBold
        case (false, true): return fontItalic
        case (false, false): return font
        }
    }
}
