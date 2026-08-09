import CoreText

struct CellMetrics {
    var cellWidth: CGFloat
    var cellHeight: CGFloat
    var fontSize: CGFloat
    var font: CTFont
    var fontBold: CTFont
    var fontItalic: CTFont
    var fontBoldItalic: CTFont
    var ascent: CGFloat

    static func measure(fontSize: CGFloat, scale: CGFloat) -> CellMetrics {
        let pxSize = fontSize * scale

        let regular = EmbeddedFonts.primary(size: pxSize, bold: false, italic: false)
        let bold = EmbeddedFonts.primary(size: pxSize, bold: true, italic: false)
        let italic = EmbeddedFonts.primary(size: pxSize, bold: false, italic: true)
        let boldItalic = EmbeddedFonts.primary(size: pxSize, bold: true, italic: true)

        // Measure "M" advance as cell width (monospace).
        var glyph = CGGlyph()
        var ch: UniChar = 0x004D // M
        CTFontGetGlyphsForCharacters(regular, &ch, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(regular, .horizontal, &glyph, &advance, 1)

        let ascent = CTFontGetAscent(regular)
        let descent = CTFontGetDescent(regular)
        let leading = CTFontGetLeading(regular)
        let height = ceil(ascent + descent + leading)

        // Metrics in points (logical), not pixels.
        let cellW = max(1, ceil(advance.width / scale))
        let cellH = max(1, ceil(height / scale))

        return CellMetrics(
            cellWidth: cellW,
            cellHeight: cellH,
            fontSize: fontSize,
            font: regular,
            fontBold: bold,
            fontItalic: italic,
            fontBoldItalic: boldItalic,
            ascent: ascent / scale
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
