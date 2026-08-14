import CoreGraphics
import CoreText
import Foundation
import Metal
import simd

/// Alpha glyph atlas → R8 Metal texture.
///
/// Glyphs are rasterized with CoreText in CG’s native bottom-left space, then
/// stored top-left for Metal. Shaped glyphs use natural bounds + bearings
/// (Ghostty-style); text keys keep a cell-boxed path for indicators.
final class GlyphAtlas {
    struct TextKey: Hashable {
        let text: String
        let bold: Bool
        let italic: Bool
    }

    struct GlyphKey: Hashable {
        let glyph: UInt16
        /// Distinguishes JetBrains vs Nerd (glyph IDs are per-face).
        let fontID: ObjectIdentifier
        let bold: Bool
        let italic: Bool
        let cellH: Int
        let cellBaseline: Int
        let fontPx: Int
        /// Included so horizontal centering (cell − face) is never stale.
        let cellW: Int
        /// `faceWidthPx * 1000` quantized for `Hashable`.
        let faceWMilli: Int
    }

    struct Entry {
        /// (u0, v0, u1, v1). v0 = top of glyph, v1 = bottom (Metal top-left).
        var uv: SIMD4<Float>
        /// Left bearing: add to cell origin (+ shaper x_offset) for top-left of ink quad.
        var bearingX: Float = 0
        /// Top bearing in top-left coords (distance from cell top to top of ink bitmap).
        var bearingY: Float = 0
        var pixelW: Float = 0
        var pixelH: Float = 0
    }

    private let device: MTLDevice
    private(set) var texture: MTLTexture
    private let atlasWidth: Int
    private let atlasHeight: Int
    private var pixels: [UInt8]
    private var shelfX = 0
    private var shelfY = 0
    private var shelfH = 0
    private var textCache: [TextKey: Entry] = [:]
    private var glyphCache: [GlyphKey: Entry] = [:]
    private var spriteCache: [SpriteKey: Entry] = [:]
    private let padding = 1
    /// Bumped on `clear()`. Mid-paint eviction invalidates earlier UVs; repaint when this changes.
    private(set) var packGeneration: Int = 0

    private struct SpriteKey: Hashable {
        let codepoint: UInt32
        let cellW: Int
        let cellH: Int
        let baseline: Int
    }

    let emptyUV = SIMD4<Float>(0, 0, 0, 0)

    init?(device: MTLDevice, width: Int = 4096, height: Int = 4096) {
        self.device = device
        self.atlasWidth = width
        self.atlasHeight = height
        self.pixels = [UInt8](repeating: 0, count: width * height)

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        self.texture = tex
        shelfX = 1
        shelfY = 0
        shelfH = 1
        uploadFull()
    }

    func clear() {
        textCache.removeAll(keepingCapacity: true)
        glyphCache.removeAll(keepingCapacity: true)
        spriteCache.removeAll(keepingCapacity: true)
        pixels = [UInt8](repeating: 0, count: atlasWidth * atlasHeight)
        shelfX = 1
        shelfY = 0
        shelfH = 1
        packGeneration &+= 1
        uploadFull()
    }

    /// Ghostty-style procedural sprite (braille, box drawing, blocks, powerline, …).
    func entrySprite(
        codepoint: UInt32,
        cellWidthPx: Int,
        cellHeightPx: Int,
        cellBaselinePx: Int
    ) -> Entry {
        let cellW = max(1, cellWidthPx)
        let cellH = max(1, cellHeightPx)
        let baseline = max(0, min(cellBaselinePx, cellH))
        let key = SpriteKey(codepoint: codepoint, cellW: cellW, cellH: cellH, baseline: baseline)
        if let hit = spriteCache[key] { return hit }

        var coverage = [UInt8](repeating: 0, count: cellW * cellH)
        guard SpriteFace.draw(
            codepoint,
            width: cellW,
            height: cellH,
            baseline: baseline,
            into: &coverage
        ) else {
            let e = Entry(uv: emptyUV)
            spriteCache[key] = e
            return e
        }

        // Blank sprites (e.g. U+2800 braille empty): no ink.
        if !coverage.contains(where: { $0 > 0 }) {
            let e = Entry(uv: emptyUV, bearingX: 0, bearingY: 0, pixelW: 0, pixelH: 0)
            spriteCache[key] = e
            return e
        }

        guard let packed = pack(
            coverage,
            cellW: cellW,
            cellH: cellH,
            bearingX: 0,
            bearingY: 0,
            pixelW: Float(cellW),
            pixelH: Float(cellH)
        ) else {
            let e = Entry(uv: emptyUV)
            spriteCache[key] = e
            return e
        }
        spriteCache[key] = packed
        return packed
    }

    /// Back-compat name used by older braille call sites.
    func entryBraille(
        codepoint: UInt32,
        cellWidthPx: Int,
        cellHeightPx: Int
    ) -> Entry {
        entrySprite(
            codepoint: codepoint,
            cellWidthPx: cellWidthPx,
            cellHeightPx: cellHeightPx,
            cellBaselinePx: cellHeightPx / 4
        )
    }

    func entry(
        text: String,
        bold: Bool,
        italic: Bool,
        font: CTFont,
        cellWidthPx: Int,
        cellHeightPx: Int,
        cellBaselinePx: Int,
        faceWidthPx: CGFloat = 0,
        fallbackFonts: [CTFont] = []
    ) -> Entry {
        let key = TextKey(text: text, bold: bold, italic: italic)
        if let hit = textCache[key] {
            return hit
        }
        guard !text.isEmpty, cellWidthPx > 0, cellHeightPx > 0 else {
            let e = Entry(uv: emptyUV)
            textCache[key] = e
            return e
        }
        let baseline = max(0, min(cellBaselinePx, cellHeightPx))
        // Same centering as glyph path / Ghostty coretext.zig.
        var dx: CGFloat = faceWidthPx > 0
            ? (CGFloat(cellWidthPx) - faceWidthPx) / 2
            : 0
        if dx < 0 {
            dx -= dx.rounded(.towardZero)
        }
        var fonts = [font]
        fonts.append(contentsOf: fallbackFonts)
        // Ghostty: after configured faces, Core Text cascade for the codepoint
        // (e.g. U+26E8 ⛨ → STIX Two Math). Cached in SystemFontFallback.
        fonts.append(contentsOf: SystemFontFallback.fonts(
            for: text, primary: font, already: fallbackFonts
        ))
        for f in fonts {
            // Skip faces that do not map every code unit (avoids .notdef tofu
            // from JetBrains Mono blocking Symbols Nerd Font icons).
            guard Self.fontCovers(f, text: text) else { continue }
            if let packed = rasterizeText(
                text: text,
                font: f,
                cellW: cellWidthPx,
                cellH: cellHeightPx,
                cellBaseline: baseline,
                faceCenterX: dx
            ) {
                textCache[key] = packed
                return packed
            }
        }
        let e = Entry(uv: emptyUV)
        textCache[key] = e
        return e
    }

    /// True if `font` maps every Unicode scalar in `text` (handles surrogates).
    static func fontCovers(_ font: CTFont, text: String) -> Bool {
        glyphs(for: text, font: font) != nil
    }

    /// One glyph per Unicode scalar, or nil if any scalar is missing.
    /// Surrogate pairs are resolved as a single scalar → one glyph.
    static func glyphs(for text: String, font: CTFont) -> [CGGlyph]? {
        guard !text.isEmpty else { return [] }
        var out: [CGGlyph] = []
        out.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            var chars = Array(String(scalar).utf16)
            var gs = [CGGlyph](repeating: 0, count: chars.count)
            let ok = CTFontGetGlyphsForCharacters(font, &chars, &gs, chars.count)
            // Non-BMP: typically one real glyph and zeros for the other unit(s).
            guard ok, let g = gs.first(where: { $0 != 0 }) else { return nil }
            out.append(g)
        }
        return out
    }

    /// True for Private Use Area (Nerd Font icons live here).
    static func isPrivateUse(_ text: String) -> Bool {
        for s in text.unicodeScalars {
            let v = s.value
            if (0xE000...0xF8FF).contains(v) { return true }
            if (0xF0000...0xFFFFD).contains(v) { return true }
            if (0x100000...0x10FFFD).contains(v) { return true }
        }
        return false
    }

    /// Rasterize a shaped CGGlyph with a **shared cell baseline**.
    ///
    /// Full cell-height strip so every glyph uses the same pen Y (`cellBaseline`
    /// from the bottom). That keeps “a” / “H” / “g” on one line (Ghostty
    /// `cell_baseline`). Horizontal ink is tight; `bearingX` includes face
    /// centering when the cell is wider than the face advance.
    ///
    /// Caller adds shaper `x_offset`. Place at cell top (`bearingY == 0`).
    func entry(
        glyph: CGGlyph,
        bold: Bool,
        italic: Bool,
        font: CTFont,
        fontPx: Int,
        cellHeightPx: Int,
        cellBaselinePx: Int,
        cellWidthPx: Int,
        faceWidthPx: CGFloat
    ) -> Entry {
        let cellH = max(1, cellHeightPx)
        let cellW = max(1, cellWidthPx)
        let baseline = max(0, min(cellBaselinePx, cellH))
        let key = GlyphKey(
            glyph: glyph, fontID: ObjectIdentifier(font as AnyObject),
            bold: bold, italic: italic,
            cellH: cellH, cellBaseline: baseline, fontPx: fontPx,
            cellW: cellW, faceWMilli: Int((faceWidthPx * 1000).rounded())
        )
        if let hit = glyphCache[key] {
            return hit
        }

        var g = glyph
        var bounds = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font, .horizontal, &g, &bounds, 1)
        if bounds.width < 0.5 || bounds.height < 0.5 {
            let e = Entry(uv: emptyUV)
            glyphCache[key] = e
            return e
        }

        // Horizontal: full ink around pen x=0 (negative LSB for coding ligas).
        let inkL = bounds.minX
        let inkR = bounds.maxX
        // Ghostty coretext.zig: center face advance in the cell; if dx is
        // negative, only keep the fractional adjustment for subpixel consistency.
        var dx: CGFloat = faceWidthPx > 0
            ? (CGFloat(max(1, cellWidthPx)) - faceWidthPx) / 2
            : 0
        if dx < 0 {
            dx -= dx.rounded(.towardZero)
        }
        // Ghostty: x = LSB + dx; offset_x = floor(x) - canvas_padding.
        let xPos = inkL + dx
        let floorX = floor(xPos)
        let fracX = xPos - floorX

        let contentW = max(1, Int(ceil((inkR - inkL) + fracX)))
        let bw = contentW + padding * 2
        let bh = cellH
        // Pen: padding + fractional LSB so subpixel placement matches Ghostty.
        let penX = CGFloat(padding) + fracX - inkL
        let penY = CGFloat(baseline)
        let bearingX = Float(floorX) - Float(padding)
        // Full-height strip: align bitmap top to cell top.
        let bearingY: Float = 0

        guard let packed = rasterizeGlyph(
            glyph: glyph,
            font: font,
            bitmapW: bw,
            bitmapH: bh,
            penX: penX,
            penY: penY,
            bearingX: bearingX,
            bearingY: bearingY,
            pixelW: Float(bw),
            pixelH: Float(bh)
        ) else {
            let e = Entry(uv: emptyUV)
            glyphCache[key] = e
            return e
        }
        glyphCache[key] = packed
        return packed
    }

    func prewarmASCII(
        font: CTFont,
        boldFont: CTFont,
        cellWidthPx: Int,
        cellHeightPx: Int,
        cellBaselinePx: Int,
        faceWidthPx: CGFloat
    ) {
        for code in 0x20...0x7E {
            let s = String(UnicodeScalar(code)!)
            _ = entry(
                text: s, bold: false, italic: false, font: font,
                cellWidthPx: cellWidthPx, cellHeightPx: cellHeightPx,
                cellBaselinePx: cellBaselinePx, faceWidthPx: faceWidthPx
            )
            _ = entry(
                text: s, bold: true, italic: false, font: boldFont,
                cellWidthPx: cellWidthPx, cellHeightPx: cellHeightPx,
                cellBaselinePx: cellBaselinePx, faceWidthPx: faceWidthPx
            )
        }
    }

    // MARK: - Private

    private func rasterizeText(
        text: String,
        font: CTFont,
        cellW: Int,
        cellH: Int,
        cellBaseline: Int,
        faceCenterX: CGFloat
    ) -> Entry? {
        guard let (coverage, anyInk) = drawToCoverage(cellW: cellW, cellH: cellH, draw: { ctx in
            ctx.textMatrix = .identity
            let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
            let attrs: [CFString: Any] = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: white as Any,
            ]
            guard let attr = CFAttributedStringCreate(
                kCFAllocatorDefault,
                text as CFString,
                attrs as CFDictionary
            ) else { return }
            let line = CTLineCreateWithAttributedString(attr)
            // Ghostty-style: pen on cell baseline from bottom; optional face centering.
            let penX = max(0, faceCenterX)
            let penY = CGFloat(max(0, min(cellBaseline, cellH)))
            ctx.textPosition = CGPoint(x: penX, y: penY)
            CTLineDraw(line, ctx)
        }) else { return nil }
        guard anyInk else { return nil }
        return pack(
            coverage,
            cellW: cellW,
            cellH: cellH,
            bearingX: 0,
            bearingY: 0,
            pixelW: Float(cellW),
            pixelH: Float(cellH)
        )
    }

    private func rasterizeGlyph(
        glyph: CGGlyph,
        font: CTFont,
        bitmapW: Int,
        bitmapH: Int,
        penX: CGFloat,
        penY: CGFloat,
        bearingX: Float,
        bearingY: Float,
        pixelW: Float,
        pixelH: Float
    ) -> Entry? {
        guard let (coverage, anyInk) = drawToCoverage(cellW: bitmapW, cellH: bitmapH, draw: { ctx in
            ctx.textMatrix = .identity
            var g = glyph
            var pos = CGPoint(x: penX, y: penY)
            CTFontDrawGlyphs(font, &g, &pos, 1, ctx)
        }) else { return nil }
        guard anyInk else { return nil }
        return pack(
            coverage,
            cellW: bitmapW,
            cellH: bitmapH,
            bearingX: bearingX,
            bearingY: bearingY,
            pixelW: pixelW,
            pixelH: pixelH
        )
    }

    private func drawToCoverage(
        cellW: Int,
        cellH: Int,
        draw: (CGContext) -> Void
    ) -> (coverage: [UInt8], anyInk: Bool)? {
        let bpr = (cellW * 4 + 15) & ~15
        var rgba = [UInt8](repeating: 0, count: bpr * cellH)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &rgba,
            width: cellW,
            height: cellH,
            bitsPerComponent: 8,
            bytesPerRow: bpr,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.setShouldAntialias(true)
        ctx.setAllowsAntialiasing(true)
        ctx.clear(CGRect(x: 0, y: 0, width: cellW, height: cellH))
        draw(ctx)

        var coverage = [UInt8](repeating: 0, count: cellW * cellH)
        var anyInk = false
        for y in 0..<cellH {
            let rowOff = y * bpr
            for x in 0..<cellW {
                let o = rowOff + x * 4
                let v = max(rgba[o + 3], rgba[o])
                coverage[y * cellW + x] = v
                if v > 8 { anyInk = true }
            }
        }
        return (coverage, anyInk)
    }

    private func pack(
        _ coverage: [UInt8],
        cellW: Int,
        cellH: Int,
        bearingX: Float,
        bearingY: Float,
        pixelW: Float,
        pixelH: Float
    ) -> Entry? {
        let w = cellW + padding * 2
        let h = cellH + padding * 2
        if let rect = allocate(width: w, height: h) {
            return write(
                coverage, cellW: cellW, cellH: cellH, rect: rect,
                bearingX: bearingX, bearingY: bearingY, pixelW: pixelW, pixelH: pixelH
            )
        }
        // Full: clear and place this glyph. packGeneration bumps so the grid repaints.
        clear()
        guard let rect = allocate(width: w, height: h) else { return nil }
        return write(
            coverage, cellW: cellW, cellH: cellH, rect: rect,
            bearingX: bearingX, bearingY: bearingY, pixelW: pixelW, pixelH: pixelH
        )
    }

    private func write(
        _ coverage: [UInt8],
        cellW: Int,
        cellH: Int,
        rect: (x: Int, y: Int, w: Int, h: Int),
        bearingX: Float,
        bearingY: Float,
        pixelW: Float,
        pixelH: Float
    ) -> Entry {
        let ox = rect.x + padding
        let oy = rect.y + padding
        for y in 0..<cellH {
            let src = y * cellW
            let dst = (oy + y) * atlasWidth + ox
            for i in 0..<cellW {
                pixels[dst + i] = coverage[src + i]
            }
        }
        upload(region: MTLRegionMake2D(rect.x, rect.y, rect.w, rect.h))

        let invW = 1.0 / Float(atlasWidth)
        let invH = 1.0 / Float(atlasHeight)
        // UV for ink interior (excluding padding).
        let u0 = Float(ox) * invW
        let v0 = Float(oy) * invH
        let u1 = Float(ox + cellW) * invW
        let v1 = Float(oy + cellH) * invH
        return Entry(
            uv: SIMD4<Float>(u0, v0, u1, v1),
            bearingX: bearingX,
            bearingY: bearingY,
            pixelW: pixelW > 0 ? pixelW : Float(cellW),
            pixelH: pixelH > 0 ? pixelH : Float(cellH)
        )
    }

    private func allocate(width: Int, height: Int) -> (x: Int, y: Int, w: Int, h: Int)? {
        if shelfX + width > atlasWidth {
            shelfY += shelfH
            shelfX = 0
            shelfH = 0
        }
        if shelfY + height > atlasHeight { return nil }
        let x = shelfX
        let y = shelfY
        shelfX += width
        shelfH = max(shelfH, height)
        return (x, y, width, height)
    }

    private func uploadFull() {
        texture.replace(
            region: MTLRegionMake2D(0, 0, atlasWidth, atlasHeight),
            mipmapLevel: 0,
            withBytes: pixels,
            bytesPerRow: atlasWidth
        )
    }

    private func upload(region: MTLRegion) {
        let x = Int(region.origin.x)
        let y = Int(region.origin.y)
        let w = Int(region.size.width)
        let h = Int(region.size.height)
        var rowBytes = [UInt8](repeating: 0, count: max(1, w * h))
        for row in 0..<h {
            let src = (y + row) * atlasWidth + x
            let dst = row * w
            for i in 0..<w {
                rowBytes[dst + i] = pixels[src + i]
            }
        }
        texture.replace(region: region, mipmapLevel: 0, withBytes: rowBytes, bytesPerRow: max(1, w))
    }
}
