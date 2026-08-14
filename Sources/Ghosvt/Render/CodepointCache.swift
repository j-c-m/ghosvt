import CoreText
import Foundation

/// Ghostty `SharedGrid.codepoints`: cache codepoint + style → face.
///
/// Negative matches are stored so a miss is not searched again.
final class CodepointCache {
    enum Hit {
        case sprite
        case glyph(font: CTFont, glyph: CGGlyph, primary: Bool)
        case missing
    }

    /// Ghostty `Collection.Index` stand-in for run splits.
    enum FaceKind: Equatable {
        case primary
        case sprite
        case fallback(ObjectIdentifier)
        case missing
    }

    private struct Key: Hashable {
        var cp: UInt32
        var bold: Bool
        var italic: Bool
        var fontPx: Int
    }

    private var map: [Key: Hit] = [:]

    func clear() {
        map.removeAll(keepingCapacity: true)
    }

    /// First font that maps `cp` (sprite, primary, Nerd, system). Cached.
    func resolve(
        cp: UInt32,
        bold: Bool,
        italic: Bool,
        fontPx: Int,
        primary: CTFont,
        nerdFaces: [CTFont]
    ) -> Hit {
        let key = Key(cp: cp, bold: bold, italic: italic, fontPx: fontPx)
        if let hit = map[key] { return hit }
        let hit = search(
            cp: cp, primary: primary, nerdFaces: nerdFaces
        )
        map[key] = hit
        return hit
    }

    /// Face used for this codepoint (cached). ASCII/empty stay `.primary`.
    func faceKind(
        cp: UInt32,
        bold: Bool,
        italic: Bool,
        fontPx: Int,
        primary: CTFont,
        nerdFaces: [CTFont]
    ) -> FaceKind {
        if cp == 0 || (cp >= 0x20 && cp <= 0x7E) { return .primary }
        switch resolve(
            cp: cp, bold: bold, italic: italic, fontPx: fontPx,
            primary: primary, nerdFaces: nerdFaces
        ) {
        case .sprite: return .sprite
        case .glyph(_, _, true): return .primary
        case .glyph(let font, _, false):
            return .fallback(ObjectIdentifier(font as AnyObject))
        case .missing: return .missing
        }
    }

    private func search(
        cp: UInt32,
        primary: CTFont,
        nerdFaces: [CTFont]
    ) -> Hit {
        if SpriteFace.covers(cp) { return .sprite }

        let preferNerd = isPrivateUse(cp) || glyph(cp, in: primary) == nil
        let order = preferNerd ? (nerdFaces + [primary]) : ([primary] + nerdFaces)
        for face in order {
            if let g = glyph(cp, in: face) {
                let isPrimary = fontIdentity(face) == fontIdentity(primary)
                return .glyph(font: face, glyph: g, primary: isPrimary)
            }
        }

        guard let scalar = UnicodeScalar(cp) else { return .missing }
        let text = String(scalar)
        if let ace = SystemFontFallback.appleColorEmoji(size: CTFontGetSize(primary)),
           let g = glyph(cp, in: ace) {
            return .glyph(font: ace, glyph: g, primary: false)
        }
        if let sys = SystemFontFallback.face(for: text, from: primary),
           let g = glyph(cp, in: sys) {
            return .glyph(font: sys, glyph: g, primary: false)
        }
        return .missing
    }

    private func glyph(_ cp: UInt32, in font: CTFont) -> CGGlyph? {
        guard let scalar = UnicodeScalar(cp) else { return nil }
        let glyphs = GlyphAtlas.glyphs(for: String(scalar), font: font)
        guard let glyphs, glyphs.count == 1 else { return nil }
        return glyphs[0]
    }

    private func fontIdentity(_ font: CTFont) -> String {
        (CTFontCopyPostScriptName(font) as String?) ?? ""
    }

    private func isPrivateUse(_ cp: UInt32) -> Bool {
        (0xE000...0xF8FF).contains(cp)
            || (0xF0000...0xFFFFD).contains(cp)
            || (0x100000...0x10FFFD).contains(cp)
    }
}
