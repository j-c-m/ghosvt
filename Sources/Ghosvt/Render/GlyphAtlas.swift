import CoreGraphics
import CoreText
import Foundation
import Metal
import simd

/// Alpha glyph atlas → R8 Metal texture.
///
/// Glyphs are rasterized with CoreText in CG’s native bottom-left space, then
/// stored top-left for Metal. Offline verification shows this produces upright
/// JetBrains Mono bitmaps.
final class GlyphAtlas {
    struct Key: Hashable {
        let text: String
        let bold: Bool
        let italic: Bool
    }

    struct Entry {
        /// (u0, v0, u1, v1). v0 = top of glyph, v1 = bottom (Metal top-left).
        var uv: SIMD4<Float>
    }

    private let device: MTLDevice
    private(set) var texture: MTLTexture
    private let atlasWidth: Int
    private let atlasHeight: Int
    private var pixels: [UInt8]
    private var shelfX = 0
    private var shelfY = 0
    private var shelfH = 0
    private var cache: [Key: Entry] = [:]
    private let padding = 1

    let emptyUV = SIMD4<Float>(0, 0, 0, 0)

    init?(device: MTLDevice, width: Int = 2048, height: Int = 2048) {
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
        cache.removeAll(keepingCapacity: true)
        pixels = [UInt8](repeating: 0, count: atlasWidth * atlasHeight)
        shelfX = 1
        shelfY = 0
        shelfH = 1
        uploadFull()
    }

    func entry(
        text: String,
        bold: Bool,
        italic: Bool,
        font: CTFont,
        cellWidthPx: Int,
        cellHeightPx: Int,
        fallbackFonts: [CTFont] = []
    ) -> Entry {
        let key = Key(text: text, bold: bold, italic: italic)
        if let hit = cache[key] { return hit }
        guard !text.isEmpty, cellWidthPx > 0, cellHeightPx > 0 else {
            let e = Entry(uv: emptyUV)
            cache[key] = e
            return e
        }
        // Try primary font, then Nerd (or other) fallbacks for missing glyphs.
        var fonts = [font]
        fonts.append(contentsOf: fallbackFonts)
        for f in fonts {
            if let packed = rasterize(text: text, font: f, cellW: cellWidthPx, cellH: cellHeightPx) {
                cache[key] = packed
                return packed
            }
        }
        let e = Entry(uv: emptyUV)
        cache[key] = e
        return e
    }

    /// Pre-rasterize printable ASCII for smoother first paint.
    func prewarmASCII(font: CTFont, boldFont: CTFont, cellWidthPx: Int, cellHeightPx: Int) {
        for code in 0x20...0x7E {
            let s = String(UnicodeScalar(code)!)
            _ = entry(
                text: s, bold: false, italic: false, font: font,
                cellWidthPx: cellWidthPx, cellHeightPx: cellHeightPx
            )
            _ = entry(
                text: s, bold: true, italic: false, font: boldFont,
                cellWidthPx: cellWidthPx, cellHeightPx: cellHeightPx
            )
        }
    }

    // MARK: - Private

    private func rasterize(text: String, font: CTFont, cellW: Int, cellH: Int) -> Entry? {
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
        ctx.textMatrix = .identity
        ctx.clear(CGRect(x: 0, y: 0, width: cellW, height: cellH))

        let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: white as Any,
        ]
        guard let attr = CFAttributedStringCreate(kCFAllocatorDefault, text as CFString, attrs as CFDictionary) else {
            return nil
        }
        let line = CTLineCreateWithAttributedString(attr)

        // CG user space: origin bottom-left. Place baseline so the glyph sits in-cell.
        let descent = CTFontGetDescent(font)
        ctx.textPosition = CGPoint(x: 1, y: max(1, descent))
        CTLineDraw(line, ctx)

        // CGBitmapContext pixel buffer is top-first: memory row 0 == top of image
        // (even though the CTM origin is bottom-left for drawing). Do NOT flip
        // when copying — a previous flip inverted every glyph on screen.
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
        guard anyInk else { return nil }
        return pack(coverage, cellW: cellW, cellH: cellH)
    }

    private func pack(_ coverage: [UInt8], cellW: Int, cellH: Int) -> Entry? {
        guard let rect = allocate(width: cellW + padding * 2, height: cellH + padding * 2) else {
            clear()
            guard let rect2 = allocate(width: cellW + padding * 2, height: cellH + padding * 2) else {
                return nil
            }
            return write(coverage, cellW: cellW, cellH: cellH, rect: rect2)
        }
        return write(coverage, cellW: cellW, cellH: cellH, rect: rect)
    }

    private func write(
        _ coverage: [UInt8],
        cellW: Int,
        cellH: Int,
        rect: (x: Int, y: Int, w: Int, h: Int)
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
        let u0 = Float(ox) * invW
        let v0 = Float(oy) * invH
        let u1 = Float(ox + cellW) * invW
        let v1 = Float(oy + cellH) * invH
        return Entry(uv: SIMD4<Float>(u0, v0, u1, v1))
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
