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
    private struct Key: Hashable {
        var text: String
        var style: TextStyleKey
        var fontPx: Int
        var ligatures: Bool
    }

    private var cache: [Key: [ShapedCell]] = [:]
    private let maxEntries = 4096
    // TEMP: cache hit/miss stats
    private var hits: UInt64 = 0
    private var misses: UInt64 = 0

    func clear() {
        cache.removeAll(keepingCapacity: true)
        fputs(
            "ghosvt: shaper clear (hits=\(hits) misses=\(misses))\n",
            stderr
        )
        hits = 0
        misses = 0
    }

    /// Shape `text` from consecutive run cells.
    /// `cellUTF16Starts` has length `cellCount + 1` (prefix UTF-16 lengths).
    func shape(
        text: String,
        cellUTF16Starts: [Int],
        style: TextStyleKey,
        font: CTFont,
        fontPx: Int,
        ligatures: Bool
    ) -> [ShapedCell] {
        let cellCount = max(0, cellUTF16Starts.count - 1)
        guard cellCount > 0, !text.isEmpty else { return [] }

        let key = Key(text: text, style: style, fontPx: fontPx, ligatures: ligatures)
        if let hit = cache[key] {
            hits += 1
            logStatsIfNeeded()
            return hit
        }

        misses += 1
        let preview = text.count > 24 ? String(text.prefix(24)) + "…" : text
        fputs(
            "ghosvt: shaper MISS \(preview.debugDescription) cells=\(cellCount) fontPx=\(fontPx) liga=\(ligatures) size=\(cache.count)\n",
            stderr
        )
        logStatsIfNeeded()

        let shaped = shapeUncached(
            text: text,
            cellUTF16Starts: cellUTF16Starts,
            font: font,
            cellCount: cellCount,
            ligatures: ligatures
        )
        if cache.count >= maxEntries {
            fputs("ghosvt: shaper cache full — flush\n", stderr)
            cache.removeAll(keepingCapacity: true)
        }
        cache[key] = shaped
        return shaped
    }

    private func logStatsIfNeeded() {
        let total = hits + misses
        if total > 0, total % 100 == 0 {
            fputs(
                "ghosvt: shaper stats hits=\(hits) misses=\(misses) size=\(cache.count)\n",
                stderr
            )
        }
    }

    // MARK: - CoreText (aligned with Ghostty coretext.zig)

    private func shapeUncached(
        text: String,
        cellUTF16Starts: [Int],
        font: CTFont,
        cellCount: Int,
        ligatures: Bool
    ) -> [ShapedCell] {
        let shapedFont = Self.font(font, ligatures: ligatures)
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: shapedFont,
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
    static func font(_ base: CTFont, ligatures: Bool) -> CTFont {
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
