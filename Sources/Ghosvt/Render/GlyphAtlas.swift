import CoreGraphics
import CoreText
import Foundation
import Metal
import simd

/// Glyph atlas. R8 grayscale (default 2048²) or BGRA color (Ghostty `atlas_color`,
/// default 512²). Doubles on full up to the Metal 2D limit.
///
/// Glyphs are rasterized with CoreText in CG’s native bottom-left space, then
/// stored top-left for Metal. Shaped glyphs use natural bounds + bearings
/// (Ghostty-style); text keys keep a cell-boxed path for indicators.
final class GlyphAtlas {
    enum Format {
        case r8
        case bgra

        var bytesPerPixel: Int { self == .r8 ? 1 : 4 }
        var pixelFormat: MTLPixelFormat { self == .r8 ? .r8Unorm : .bgra8Unorm }
    }
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
        /// Ghostty `Presentation.emoji` → color atlas.
        var color: Bool = false
    }

    private let device: MTLDevice
    let format: Format
    private(set) var texture: MTLTexture
    private var atlasWidth: Int
    private var atlasHeight: Int
    private var pixels: [UInt8]
    private var shelfX = 0
    private var shelfY = 0
    private var shelfH = 0
    private var textCache: [TextKey: Entry] = [:]
    private var glyphCache: [GlyphKey: Entry] = [:]
    private var spriteCache: [SpriteKey: Entry] = [:]
    private let padding = 1
    /// Bumped on `clear()` / `grow()`. Live instance UVs are stale until the grid repaints.
    private(set) var packGeneration: Int = 0
    /// Metal 2D limit on Apple Silicon / modern Mac GPUs.
    private static let maxAtlasEdge = 16384

    private struct SpriteKey: Hashable {
        let codepoint: UInt32
        let cellW: Int
        let cellH: Int
        let baseline: Int
    }

    let emptyUV = SIMD4<Float>(0, 0, 0, 0)

    init?(
        device: MTLDevice,
        format: Format = .r8,
        width: Int? = nil,
        height: Int? = nil
    ) {
        self.device = device
        self.format = format
        let edge = width ?? (format == .r8 ? 2048 : 512)
        let h = height ?? edge
        self.atlasWidth = edge
        self.atlasHeight = h
        self.pixels = [UInt8](repeating: 0, count: edge * h * format.bytesPerPixel)
        guard let tex = Self.makeTexture(
            device: device, format: format, width: edge, height: h
        ) else {
            return nil
        }
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
        pixels = [UInt8](repeating: 0, count: atlasWidth * atlasHeight * format.bytesPerPixel)
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
            // Color fonts (Apple Color Emoji) go through `entryColor` + BGRA atlas.
            guard !Self.hasColorGlyphs(f) else { continue }
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

    /// Ghostty `Face.hasColor` / `color_glyphs` trait (Apple Color Emoji, Noto Color).
    static func hasColorGlyphs(_ font: CTFont) -> Bool {
        CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs)
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

    /// Color emoji (Ghostty `atlas_color` + `constraint.size = .cover`).
    func entryColor(
        glyph: CGGlyph,
        font: CTFont,
        cellWidthPx: Int,
        cellHeightPx: Int
    ) -> Entry {
        let cellH = max(1, cellHeightPx)
        let cellW = max(1, cellWidthPx)
        let key = GlyphKey(
            glyph: glyph, fontID: ObjectIdentifier(font as AnyObject),
            bold: false, italic: false,
            cellH: cellH, cellBaseline: 0, fontPx: 0,
            cellW: cellW, faceWMilli: 0
        )
        if let hit = glyphCache[key] { return hit }

        var g = glyph
        var bounds = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font, .horizontal, &g, &bounds, 1)
        if bounds.width < 0.5 || bounds.height < 0.5 {
            let e = Entry(uv: emptyUV, color: true)
            glyphCache[key] = e
            return e
        }

        // Ghostty emoji: cover, center, pad_left/right 0.025.
        let padFrac: CGFloat = 0.025
        let availW = CGFloat(cellW) * (1 - 2 * padFrac)
        let availH = CGFloat(cellH)
        let scale = min(availW / bounds.width, availH / bounds.height)
        let destW = bounds.width * scale
        let destH = bounds.height * scale
        let canvasW = max(1, Int(ceil(destW)))
        let canvasH = max(1, Int(ceil(destH)))
        let bearingX = Float((CGFloat(cellW) - destW) / 2)
        let bearingY = Float((CGFloat(cellH) - destH) / 2)

        guard let packed = rasterizeColor(
            glyph: glyph,
            font: font,
            bounds: bounds,
            canvasW: canvasW,
            canvasH: canvasH,
            destW: destW,
            destH: destH,
            bearingX: bearingX,
            bearingY: bearingY
        ) else {
            let e = Entry(uv: emptyUV, color: true)
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

    private func rasterizeColor(
        glyph: CGGlyph,
        font: CTFont,
        bounds: CGRect,
        canvasW: Int,
        canvasH: Int,
        destW: CGFloat,
        destH: CGFloat,
        bearingX: Float,
        bearingY: Float
    ) -> Entry? {
        let bpr = canvasW * 4
        var bgra = [UInt8](repeating: 0, count: bpr * canvasH)
        let space = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo =
            CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(
            data: &bgra,
            width: canvasW,
            height: canvasH,
            bitsPerComponent: 8,
            bytesPerRow: bpr,
            space: space,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        ctx.setShouldAntialias(true)
        ctx.setAllowsAntialiasing(true)
        ctx.setAllowsFontSubpixelPositioning(true)
        ctx.setShouldSubpixelPositionFonts(true)
        ctx.setAllowsFontSubpixelQuantization(false)
        ctx.setShouldSubpixelQuantizeFonts(false)
        ctx.clear(CGRect(x: 0, y: 0, width: canvasW, height: canvasH))
        ctx.scaleBy(x: destW / bounds.width, y: destH / bounds.height)
        var g = glyph
        var pos = CGPoint(x: -bounds.minX, y: -bounds.minY)
        CTFontDrawGlyphs(font, &g, &pos, 1, ctx)

        return pack(
            bgra,
            cellW: canvasW,
            cellH: canvasH,
            bearingX: bearingX,
            bearingY: bearingY,
            pixelW: Float(canvasW),
            pixelH: Float(canvasH)
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
        // Ghostty SharedGrid: AtlasFull → grow(size * 2), keep packed glyphs.
        if grow(), let rect = allocate(width: w, height: h) {
            return write(
                coverage, cellW: cellW, cellH: cellH, rect: rect,
                bearingX: bearingX, bearingY: bearingY, pixelW: pixelW, pixelH: pixelH
            )
        }
        // At Metal max (or grow failed): evict and place this glyph.
        clear()
        guard let rect = allocate(width: w, height: h) else { return nil }
        return write(
            coverage, cellW: cellW, cellH: cellH, rect: rect,
            bearingX: bearingX, bearingY: bearingY, pixelW: pixelW, pixelH: pixelH
        )
    }

    private static func makeTexture(
        device: MTLDevice,
        format: Format,
        width: Int,
        height: Int
    ) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format.pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        return device.makeTexture(descriptor: desc)
    }

    /// Double the atlas (square, Ghostty `Atlas.grow`). Copies ink; rescales cached UVs.
    @discardableResult
    private func grow() -> Bool {
        let oldW = atlasWidth
        let oldH = atlasHeight
        let newW = min(oldW * 2, Self.maxAtlasEdge)
        let newH = min(oldH * 2, Self.maxAtlasEdge)
        if newW <= oldW && newH <= oldH { return false }
        guard let tex = Self.makeTexture(
            device: device, format: format, width: newW, height: newH
        ) else {
            return false
        }

        let bpp = format.bytesPerPixel
        var next = [UInt8](repeating: 0, count: newW * newH * bpp)
        pixels.withUnsafeBufferPointer { src in
            guard let s = src.baseAddress else { return }
            next.withUnsafeMutableBufferPointer { dst in
                guard let d = dst.baseAddress else { return }
                let srcStride = oldW * bpp
                let dstStride = newW * bpp
                for y in 0..<oldH {
                    d.advanced(by: y * dstStride)
                        .update(from: s.advanced(by: y * srcStride), count: srcStride)
                }
            }
        }

        let scale = SIMD4<Float>(
            Float(oldW) / Float(newW),
            Float(oldH) / Float(newH),
            Float(oldW) / Float(newW),
            Float(oldH) / Float(newH)
        )
        rescaleUVs(&textCache, by: scale)
        rescaleUVs(&glyphCache, by: scale)
        rescaleUVs(&spriteCache, by: scale)

        pixels = next
        atlasWidth = newW
        atlasHeight = newH
        texture = tex
        // Packed ink occupies [0, oldW) × [0, oldH). Resume on the new bottom band.
        shelfX = 0
        shelfY = oldH
        shelfH = 0
        packGeneration &+= 1
        uploadFull()
        return true
    }

    private func rescaleUVs<K: Hashable>(_ cache: inout [K: Entry], by scale: SIMD4<Float>) {
        for (key, var entry) in cache {
            entry.uv *= scale
            cache[key] = entry
        }
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
        let bpp = format.bytesPerPixel
        coverage.withUnsafeBufferPointer { src in
            guard let s = src.baseAddress else { return }
            pixels.withUnsafeMutableBufferPointer { dst in
                guard let d = dst.baseAddress else { return }
                for y in 0..<cellH {
                    d.advanced(by: ((oy + y) * atlasWidth + ox) * bpp)
                        .update(from: s.advanced(by: y * cellW * bpp), count: cellW * bpp)
                }
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
            pixelH: pixelH > 0 ? pixelH : Float(cellH),
            color: format == .bgra
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
        let rowBytes = atlasWidth * format.bytesPerPixel
        texture.replace(
            region: MTLRegionMake2D(0, 0, atlasWidth, atlasHeight),
            mipmapLevel: 0,
            withBytes: pixels,
            bytesPerRow: rowBytes
        )
    }

    private func upload(region: MTLRegion) {
        let bpp = format.bytesPerPixel
        let x = Int(region.origin.x)
        let y = Int(region.origin.y)
        let w = Int(region.size.width)
        let h = Int(region.size.height)
        var rowBytes = [UInt8](repeating: 0, count: max(1, w * h * bpp))
        for row in 0..<h {
            let src = ((y + row) * atlasWidth + x) * bpp
            let dst = row * w * bpp
            for i in 0..<(w * bpp) {
                rowBytes[dst + i] = pixels[src + i]
            }
        }
        texture.replace(
            region: region,
            mipmapLevel: 0,
            withBytes: rowBytes,
            bytesPerRow: max(1, w * bpp)
        )
    }
}
