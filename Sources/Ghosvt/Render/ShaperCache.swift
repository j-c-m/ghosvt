import CoreGraphics
import CoreText
import Foundation

/// Text style that ends a shaping run (background ignored — applied at draw).
struct TextStyleKey: Hashable {
    var fr: UInt8
    var fg: UInt8
    var fb: UInt8
    var bold: Bool
    var italic: Bool
    var faint: Bool
    var inverse: Bool
    var underline: Bool
}

/// One shaped glyph, Ghostty-style: grid cell + pixel offset within the run.
///
/// Coding ligatures (e.g. JetBrains `=>`) are typically a spacer glyph on the
/// first cell and a wide ink glyph on a later cell with a negative `xOffset`
/// so the ink spans multiple cells. We do **not** invent multi-cell quads.
struct ShapedCell: Sendable {
    /// Column relative to the run start (cluster).
    var x: UInt16
    /// Extra horizontal offset in pixels from the cell origin (can be negative).
    var xOffset: Int16
    var yOffset: Int16
    var glyph: CGGlyph
}

/// CoreText run shaper with a placement cache (mirrors Ghostty’s shape.Cell model).
final class ShaperCache {
    /// Ghostty `TextRun.hash`: (cp, relative cluster)* + length + face.
    private var cache: [UInt64: [ShapedCell]] = [:]
    private let maxEntries = 4096
    private var featured: [FeaturedKey: CTFont] = [:]

    private struct FeaturedKey: Hashable {
        var id: ObjectIdentifier
        var ligatures: Bool
    }

    static let fnvOffset: UInt64 = 14_695_981_039_346_656_037
    private static let fnvPrime: UInt64 = 1_099_511_628_211

    static func mix(_ digest: inout UInt64, _ v: UInt64) {
        digest ^= v
        digest &*= fnvPrime
    }

    /// Mix one cell into a run content hash (Ghostty `addCodepoint`).
    static func mixCell(_ digest: inout UInt64, cp: UInt32, cluster: Int) {
        mix(&digest, UInt64(cp == 0 ? 32 : cp))
        mix(&digest, UInt64(cluster))
    }

    func clear() {
        cache.removeAll(keepingCapacity: true)
        featured.removeAll(keepingCapacity: true)
    }

    /// Featured face (liga/calt/dlig). Cached per base font.
    func featuredFont(_ base: CTFont, ligatures: Bool) -> CTFont {
        let key = FeaturedKey(id: ObjectIdentifier(base as AnyObject), ligatures: ligatures)
        if let hit = featured[key] { return hit }
        let created = Self.makeFeatured(base, ligatures: ligatures)
        featured[key] = created
        return created
    }

    /// Lookup by precomputed content hash. Builds the Core Text string on miss only.
    func shape(
        cells: [TerminalRowCell],
        start: Int,
        end: Int,
        contentHash: UInt64,
        font: CTFont,
        fontPx: Int,
        ligatures: Bool,
        bold: Bool,
        italic: Bool
    ) -> [ShapedCell] {
        guard start < end, start >= 0, end <= cells.count else { return [] }

        var digest = contentHash
        Self.mix(&digest, UInt64(fontPx))
        Self.mix(&digest, ligatures ? 1 : 0)
        Self.mix(&digest, bold ? 1 : 0)
        Self.mix(&digest, italic ? 1 : 0)

        if let hit = cache[digest] {
            return hit
        }

        var text = ""
        var utf16Starts: [Int] = [0]
        utf16Starts.reserveCapacity(end - start + 1)
        text.reserveCapacity(end - start)
        for col in start..<end {
            let raw = cells[col].text
            text += raw.isEmpty ? " " : raw
            utf16Starts.append(text.utf16.count)
        }
        guard !text.isEmpty else { return [] }

        let shaped = shapeUncached(
            text: text,
            cellUTF16Starts: utf16Starts,
            font: font,
            cellCount: end - start
        )
        if cache.count < maxEntries {
            cache[digest] = shaped
        }
        return shaped
    }

    // MARK: - CoreText (aligned with Ghostty coretext.zig)

    private func shapeUncached(
        text: String,
        cellUTF16Starts: [Int],
        font: CTFont,
        cellCount: Int
    ) -> [ShapedCell] {
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: font,
        ]
        guard let attr = CFAttributedStringCreate(
            kCFAllocatorDefault,
            text as CFString,
            attrs as CFDictionary
        ) else { return [] }

        // Ghostty: CTTypesetter with forced LTR embedding (level 0) so BiDi
        // does not reorder runs and break cell-relative x offsets.
        let level = NSNumber(value: 0)
        let tsOpts: [CFString: Any] = [
            kCTTypesetterOptionForcedEmbeddingLevel: level,
        ]
        guard let typesetter = CTTypesetterCreateWithAttributedStringAndOptions(
            attr,
            tsOpts as CFDictionary
        ) else { return [] }
        let line = CTTypesetterCreateLine(typesetter, CFRange(location: 0, length: 0))
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return [] }

        // Ghostty: track cumulative advance (run_offset) and cell pen origin (cell_offset).
        // Both start at cluster 0 / x 0 (same as Ghostty Offset defaults).
        var runOffsetX: CGFloat = 0
        var runOffsetCluster: Int = 0
        var cellOffsetX: CGFloat = 0
        var cellOffsetCluster: Int = 0

        var out: [ShapedCell] = []
        out.reserveCapacity(cellCount)

        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }

            var glyphs = [CGGlyph](repeating: 0, count: count)
            var advances = [CGSize](repeating: .zero, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            let range = CFRange(location: 0, length: count)
            CTRunGetGlyphs(run, range, &glyphs)
            CTRunGetAdvances(run, range, &advances)
            CTRunGetPositions(run, range, &positions)
            CTRunGetStringIndices(run, range, &indices)

            for i in 0..<count {
                let utf16Index = Int(indices[i])
                let cluster = Self.cellIndex(utf16: utf16Index, starts: cellUTF16Starts)
                guard cluster >= 0, cluster < cellCount else {
                    runOffsetX += advances[i].width
                    continue
                }

                // When cluster changes, optionally reset cell pen (Ghostty heuristic).
                if cellOffsetCluster != cluster {
                    let isAfter = cluster <= runOffsetCluster
                    let isFirstInCluster = Self.isFirstCodepoint(
                        utf16Index: utf16Index,
                        cluster: cluster,
                        starts: cellUTF16Starts,
                        textUTF16Count: cellUTF16Starts.last ?? 0
                    )
                    // Ligature tails: first codepoint of a new cluster that was
                    // already consumed → do not snap cell pen back to the grid.
                    if isFirstInCluster && !isAfter {
                        cellOffsetCluster = cluster
                        cellOffsetX = runOffsetX
                    }
                }

                // Ghostty: round (not trunc) for i16 bearings.
                let xOffset = Int16((positions[i].x - cellOffsetX).rounded())
                let yOffset = Int16(positions[i].y.rounded())
                out.append(ShapedCell(
                    x: UInt16(cluster),
                    xOffset: xOffset,
                    yOffset: yOffset,
                    glyph: glyphs[i]
                ))

                runOffsetX += advances[i].width
                runOffsetCluster = max(runOffsetCluster, cluster)
            }
        }
        return out
    }

    private static func isFirstCodepoint(
        utf16Index: Int,
        cluster: Int,
        starts: [Int],
        textUTF16Count: Int
    ) -> Bool {
        _ = textUTF16Count
        // First UTF-16 unit of this cell in the run string.
        guard cluster < starts.count - 1 else { return true }
        return utf16Index == starts[cluster]
    }

    private static func cellIndex(utf16: Int, starts: [Int]) -> Int {
        var lo = 0
        var hi = starts.count - 2
        var ans = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if starts[mid] <= utf16 {
                ans = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return ans
    }

    /// Merge liga/calt/dlig onto the face (Ghostty default features when enabled).
    private static func makeFeatured(_ base: CTFont, ligatures: Bool) -> CTFont {
        let value = NSNumber(value: ligatures ? 1 : 0)
        let features: [[CFString: Any]] = [
            [kCTFontOpenTypeFeatureTag: "liga" as CFString, kCTFontOpenTypeFeatureValue: value],
            [kCTFontOpenTypeFeatureTag: "calt" as CFString, kCTFontOpenTypeFeatureValue: value],
            [kCTFontOpenTypeFeatureTag: "dlig" as CFString, kCTFontOpenTypeFeatureValue: value],
        ]
        let baseDesc = CTFontCopyFontDescriptor(base)
        let desc = CTFontDescriptorCreateCopyWithAttributes(
            baseDesc,
            [kCTFontFeatureSettingsAttribute: features] as CFDictionary
        )
        return CTFontCreateWithFontDescriptor(desc, CTFontGetSize(base), nil)
    }
}
