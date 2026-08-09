import Foundation

/// Ghostty-style built-in sprite face: box drawing, blocks, braille, powerline, etc.
///
/// Draw modules register ranges; unknown codepoints return false from `covers`.
enum SpriteFace {
    /// True if we procedurally draw this codepoint (do not use a font).
    static func covers(_ cp: UInt32) -> Bool {
        if BrailleSprite.codepointRange.contains(cp) { return true }
        if BlockSprites.covers(cp) { return true }
        if BoxSprites.covers(cp) { return true }
        if GeometricSprites.covers(cp) { return true }
        if PowerlineSprites.covers(cp) { return true }
        if BranchSprites.covers(cp) { return true }
        if LegacySprites.covers(cp) { return true }
        return false
    }

    static func covers(text: String) -> Bool {
        guard text.unicodeScalars.count == 1,
              let v = text.unicodeScalars.first?.value
        else { return false }
        return covers(v)
    }

    /// Draw into a full-cell R8 coverage buffer. Returns false if not a sprite cp.
    @discardableResult
    static func draw(
        _ cp: UInt32,
        width: Int,
        height: Int,
        baseline: Int,
        into coverage: inout [UInt8]
    ) -> Bool {
        guard covers(cp) else { return false }
        let w = max(1, width)
        let h = max(1, height)
        let metrics = SpriteMetrics(cellWidth: w, cellHeight: h, cellBaseline: baseline)
        let canvas = SpriteCanvas(width: w, height: h)

        if BrailleSprite.codepointRange.contains(cp) {
            var buf = canvas.pixels
            _ = BrailleSprite.fillCoverage(codepoint: cp, width: w, height: h, into: &buf)
            coverage = buf
            return true
        }
        if BlockSprites.covers(cp) {
            BlockSprites.draw(cp, canvas: canvas, metrics: metrics)
        } else if BoxSprites.covers(cp) {
            BoxSprites.draw(cp, canvas: canvas, metrics: metrics)
        } else if GeometricSprites.covers(cp) {
            GeometricSprites.draw(cp, canvas: canvas, metrics: metrics)
        } else if PowerlineSprites.covers(cp) {
            PowerlineSprites.draw(cp, canvas: canvas, metrics: metrics)
        } else if BranchSprites.covers(cp) {
            BranchSprites.draw(cp, canvas: canvas, metrics: metrics)
        } else if LegacySprites.covers(cp) {
            LegacySprites.draw(cp, canvas: canvas, metrics: metrics)
        } else {
            return false
        }

        coverage = canvas.pixels
        if coverage.count != w * h {
            coverage = Array(coverage.prefix(w * h))
            if coverage.count < w * h {
                coverage.append(contentsOf: repeatElement(0, count: w * h - coverage.count))
            }
        }
        return true
    }
}
