import CoreGraphics
import Foundation

/// Procedural Braille Patterns (U+2800…U+28FF), matching Ghostty’s sprite face.
///
/// Dot layout (Unicode bit order):
/// ```
///  0  3
///  1  4
///  2  5
///  6  7
/// ```
enum BrailleSprite {
    static let codepointRange: ClosedRange<UInt32> = 0x2800...0x28FF

    static func isBraille(_ text: String) -> Bool {
        guard text.unicodeScalars.count == 1,
              let v = text.unicodeScalars.first?.value
        else { return false }
        return codepointRange.contains(v)
    }

    static func codepoint(from text: String) -> UInt32? {
        guard isBraille(text), let v = text.unicodeScalars.first?.value else { return nil }
        return v
    }

    /// Fill an R8 coverage buffer (top-left origin) with braille dots.
    /// Returns false only if dimensions are invalid.
    static func fillCoverage(
        codepoint: UInt32,
        width: Int,
        height: Int,
        into coverage: inout [UInt8]
    ) -> Bool {
        guard codepointRange.contains(codepoint),
              width > 0, height > 0,
              coverage.count >= width * height
        else { return false }

        coverage.replaceSubrange(0..<(width * height), with: repeatElement(0, count: width * height))

        // Ghostty braille.zig packing / spacing heuristic.
        var w = min(width / 4, height / 8)
        var xSpacing = width / 4
        var ySpacing = height / 8
        var xMargin = xSpacing / 2
        var yMargin = ySpacing / 2

        var xLeft = width - 2 * xMargin - xSpacing - 2 * w
        var yLeft = height - 2 * yMargin - 3 * ySpacing - 4 * w

        if xLeft >= 2, yLeft >= 4, w == 0 {
            w += 1
            xLeft -= 2
            yLeft -= 4
        }
        if xLeft >= 2, xMargin == 0 {
            xMargin = 1
            xLeft -= 2
        }
        if yLeft >= 2, yMargin == 0 {
            yMargin = 1
            yLeft -= 2
        }
        if xLeft >= 1 {
            xSpacing += 1
            xLeft -= 1
        }
        if yLeft >= 3 {
            ySpacing += 1
            yLeft -= 3
        }
        if xLeft >= 2 {
            xMargin += 1
            xLeft -= 2
        }
        if yLeft >= 2 {
            yMargin += 1
            yLeft -= 2
        }
        if xLeft >= 2, yLeft >= 4 {
            w += 1
        }

        w = max(1, w)

        let xs = [xMargin, xMargin + w + xSpacing]
        var ys = [0, 0, 0, 0]
        ys[0] = yMargin
        ys[1] = ys[0] + w + ySpacing
        ys[2] = ys[1] + w + ySpacing
        ys[3] = ys[2] + w + ySpacing

        // Bit layout matches Unicode / Ghostty packed struct.
        let bits = UInt8(truncatingIfNeeded: codepoint & 0xFF)
        let dots: [(col: Int, row: Int, bit: UInt8)] = [
            (0, 0, 1 << 0), // tl
            (0, 1, 1 << 1), // ul
            (0, 2, 1 << 2), // ll
            (1, 0, 1 << 3), // tr
            (1, 1, 1 << 4), // ur
            (1, 2, 1 << 5), // lr
            (0, 3, 1 << 6), // bl
            (1, 3, 1 << 7), // br
        ]

        for d in dots where bits & d.bit != 0 {
            let x0 = xs[d.col]
            let y0 = ys[d.row]
            fillBox(
                x0: x0, y0: y0, size: w,
                width: width, height: height,
                into: &coverage
            )
        }
        return true
    }

    private static func fillBox(
        x0: Int, y0: Int, size: Int,
        width: Int, height: Int,
        into coverage: inout [UInt8]
    ) {
        let x1 = min(width, x0 + size)
        let y1 = min(height, y0 + size)
        let xStart = max(0, x0)
        let yStart = max(0, y0)
        guard xStart < x1, yStart < y1 else { return }
        for y in yStart..<y1 {
            let row = y * width
            for x in xStart..<x1 {
                coverage[row + x] = 255
            }
        }
    }
}
