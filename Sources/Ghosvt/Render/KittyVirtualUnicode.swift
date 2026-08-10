import CGhosttyVT
import Foundation

/// Kitty unicode virtual-placement helpers (U+10EEEE + diacritics).
/// Port of Ghostty `terminal/kitty/graphics_unicode.zig`.
enum KittyVirtualUnicode {
    /// Placeholder codepoint written into cells for virtual placements.
    static let placeholder: UInt32 = 0x10EEEE

    /// Virtual placements always render at z = -1 (below text) in Ghostty.
    static let virtualZ: Int32 = -1

    static let diacritics: [UInt32] = [
        0x305,
        0x30D,
        0x30E,
        0x310,
        0x312,
        0x33D,
        0x33E,
        0x33F,
        0x346,
        0x34A,
        0x34B,
        0x34C,
        0x350,
        0x351,
        0x352,
        0x357,
        0x35B,
        0x363,
        0x364,
        0x365,
        0x366,
        0x367,
        0x368,
        0x369,
        0x36A,
        0x36B,
        0x36C,
        0x36D,
        0x36E,
        0x36F,
        0x483,
        0x484,
        0x485,
        0x486,
        0x487,
        0x592,
        0x593,
        0x594,
        0x595,
        0x597,
        0x598,
        0x599,
        0x59C,
        0x59D,
        0x59E,
        0x59F,
        0x5A0,
        0x5A1,
        0x5A8,
        0x5A9,
        0x5AB,
        0x5AC,
        0x5AF,
        0x5C4,
        0x610,
        0x611,
        0x612,
        0x613,
        0x614,
        0x615,
        0x616,
        0x617,
        0x657,
        0x658,
        0x659,
        0x65A,
        0x65B,
        0x65D,
        0x65E,
        0x6D6,
        0x6D7,
        0x6D8,
        0x6D9,
        0x6DA,
        0x6DB,
        0x6DC,
        0x6DF,
        0x6E0,
        0x6E1,
        0x6E2,
        0x6E4,
        0x6E7,
        0x6E8,
        0x6EB,
        0x6EC,
        0x730,
        0x732,
        0x733,
        0x735,
        0x736,
        0x73A,
        0x73D,
        0x73F,
        0x740,
        0x741,
        0x743,
        0x745,
        0x747,
        0x749,
        0x74A,
        0x7EB,
        0x7EC,
        0x7ED,
        0x7EE,
        0x7EF,
        0x7F0,
        0x7F1,
        0x7F3,
        0x816,
        0x817,
        0x818,
        0x819,
        0x81B,
        0x81C,
        0x81D,
        0x81E,
        0x81F,
        0x820,
        0x821,
        0x822,
        0x823,
        0x825,
        0x826,
        0x827,
        0x829,
        0x82A,
        0x82B,
        0x82C,
        0x82D,
        0x951,
        0x953,
        0x954,
        0xF82,
        0xF83,
        0xF86,
        0xF87,
        0x135D,
        0x135E,
        0x135F,
        0x17DD,
        0x193A,
        0x1A17,
        0x1A75,
        0x1A76,
        0x1A77,
        0x1A78,
        0x1A79,
        0x1A7A,
        0x1A7B,
        0x1A7C,
        0x1B6B,
        0x1B6D,
        0x1B6E,
        0x1B6F,
        0x1B70,
        0x1B71,
        0x1B72,
        0x1B73,
        0x1CD0,
        0x1CD1,
        0x1CD2,
        0x1CDA,
        0x1CDB,
        0x1CE0,
        0x1DC0,
        0x1DC1,
        0x1DC3,
        0x1DC4,
        0x1DC5,
        0x1DC6,
        0x1DC7,
        0x1DC8,
        0x1DC9,
        0x1DCB,
        0x1DCC,
        0x1DD1,
        0x1DD2,
        0x1DD3,
        0x1DD4,
        0x1DD5,
        0x1DD6,
        0x1DD7,
        0x1DD8,
        0x1DD9,
        0x1DDA,
        0x1DDB,
        0x1DDC,
        0x1DDD,
        0x1DDE,
        0x1DDF,
        0x1DE0,
        0x1DE1,
        0x1DE2,
        0x1DE3,
        0x1DE4,
        0x1DE5,
        0x1DE6,
        0x1DFE,
        0x20D0,
        0x20D1,
        0x20D4,
        0x20D5,
        0x20D6,
        0x20D7,
        0x20DB,
        0x20DC,
        0x20E1,
        0x20E7,
        0x20E9,
        0x20F0,
        0x2CEF,
        0x2CF0,
        0x2CF1,
        0x2DE0,
        0x2DE1,
        0x2DE2,
        0x2DE3,
        0x2DE4,
        0x2DE5,
        0x2DE6,
        0x2DE7,
        0x2DE8,
        0x2DE9,
        0x2DEA,
        0x2DEB,
        0x2DEC,
        0x2DED,
        0x2DEE,
        0x2DEF,
        0x2DF0,
        0x2DF1,
        0x2DF2,
        0x2DF3,
        0x2DF4,
        0x2DF5,
        0x2DF6,
        0x2DF7,
        0x2DF8,
        0x2DF9,
        0x2DFA,
        0x2DFB,
        0x2DFC,
        0x2DFD,
        0x2DFE,
        0x2DFF,
        0xA66F,
        0xA67C,
        0xA67D,
        0xA6F0,
        0xA6F1,
        0xA8E0,
        0xA8E1,
        0xA8E2,
        0xA8E3,
        0xA8E4,
        0xA8E5,
        0xA8E6,
        0xA8E7,
        0xA8E8,
        0xA8E9,
        0xA8EA,
        0xA8EB,
        0xA8EC,
        0xA8ED,
        0xA8EE,
        0xA8EF,
        0xA8F0,
        0xA8F1,
        0xAAB0,
        0xAAB2,
        0xAAB3,
        0xAAB7,
        0xAAB8,
        0xAABE,
        0xAABF,
        0xAAC1,
        0xFE20,
        0xFE21,
        0xFE22,
        0xFE23,
        0xFE24,
        0xFE25,
        0xFE26,
        0x10A0F,
        0x10A38,
        0x1D185,
        0x1D186,
        0x1D187,
        0x1D188,
        0x1D189,
        0x1D1AA,
        0x1D1AB,
        0x1D1AC,
        0x1D1AD,
        0x1D242,
        0x1D243,
        0x1D244
    ]

    /// Binary search diacritic → 0-based index (nil if unknown).
    static func diacriticIndex(_ cp: UInt32) -> UInt32? {
        var lo = 0
        var hi = diacritics.count
        while lo < hi {
            let mid = (lo + hi) / 2
            let v = diacritics[mid]
            if v == cp { return UInt32(mid) }
            if v < cp { lo = mid + 1 } else { hi = mid }
        }
        return nil
    }

    /// Pack style color into a Kitty protocol ID (24 bits).
    static func colorToId(_ c: GhosttyStyleColor) -> UInt32 {
        switch c.tag {
        case GHOSTTY_STYLE_COLOR_NONE:
            return 0
        case GHOSTTY_STYLE_COLOR_PALETTE:
            return UInt32(c.value.palette)
        case GHOSTTY_STYLE_COLOR_RGB:
            let r = UInt32(c.value.rgb.r)
            let g = UInt32(c.value.rgb.g)
            let b = UInt32(c.value.rgb.b)
            return (r << 16) | (g << 8) | b
        default:
            return 0
        }
    }

    /// One incomplete cell (may merge into a horizontal run).
    struct Incomplete {
        var viewportCol: Int
        var viewportRow: Int
        var imageIdLow: UInt32
        var imageIdHigh: UInt32?
        var placementId: UInt32?
        var fragRow: UInt32?
        var fragCol: UInt32?
        var width: UInt32

        var imageId: UInt32 {
            let high = imageIdHigh ?? 0
            return imageIdLow | (high << 24)
        }

        /// Decode from style + grapheme codepoints (base + combining).
        static func decode(
            viewportCol: Int,
            viewportRow: Int,
            style: GhosttyStyle,
            graphemes: UnsafeBufferPointer<UInt32>
        ) -> Incomplete {
            let fgId = KittyVirtualUnicode.colorToId(style.fg_color)
            let ulId = KittyVirtualUnicode.colorToId(style.underline_color)
            var inc = Incomplete(
                viewportCol: viewportCol,
                viewportRow: viewportRow,
                imageIdLow: fgId,
                imageIdHigh: nil,
                placementId: ulId != 0 ? ulId : nil,
                fragRow: nil,
                fragCol: nil,
                width: 1
            )
            // graphemes[0] is base (U+10EEEE); diacritics follow.
            let cps = Array(graphemes)
            if cps.count > 1 {
                inc.fragRow = KittyVirtualUnicode.diacriticIndex(cps[1])
            }
            if cps.count > 2 {
                inc.fragCol = KittyVirtualUnicode.diacriticIndex(cps[2])
            }
            if cps.count > 3 {
                if let high = KittyVirtualUnicode.diacriticIndex(cps[3]), high <= 255 {
                    inc.imageIdHigh = high
                }
            }
            return inc
        }

        mutating func seedDefaults() {
            if fragRow == nil { fragRow = 0 }
            if fragCol == nil { fragCol = 0 }
        }

        func canAppend(_ other: Incomplete) -> Bool {
            guard imageIdLow == other.imageIdLow,
                  placementId == other.placementId
            else { return false }
            if let or = other.fragRow, or != fragRow { return false }
            if let oc = other.fragCol {
                guard let sc = fragCol else { return false }
                if oc != sc + width { return false }
            }
            if let oh = other.imageIdHigh, oh != imageIdHigh { return false }
            return true
        }

        mutating func append(_ other: Incomplete) -> Bool {
            guard canAppend(other) else { return false }
            width += 1
            return true
        }

        func complete() -> Placement {
            Placement(
                viewportCol: viewportCol,
                viewportRow: viewportRow,
                imageId: imageId,
                placementId: placementId ?? 0,
                fragCol: fragCol ?? 0,
                fragRow: fragRow ?? 0,
                width: width,
                height: 1
            )
        }
    }

    /// Completed virtual placement run (one row high).
    struct Placement {
        var viewportCol: Int
        var viewportRow: Int
        var imageId: UInt32
        var placementId: UInt32
        var fragCol: UInt32
        var fragRow: UInt32
        var width: UInt32
        var height: UInt32
    }

    /// Resolved GPU draw parameters for one virtual run.
    struct RenderPlacement {
        var offsetX: UInt32
        var offsetY: UInt32
        var sourceX: UInt32
        var sourceY: UInt32
        var sourceWidth: UInt32
        var sourceHeight: UInt32
        var destWidth: UInt32
        var destHeight: UInt32
    }

    /// Grid size for a virtual placement (from storage meta + image size).
    static func gridSize(
        columns: UInt32,
        rows: UInt32,
        imageWidth: UInt32,
        imageHeight: UInt32,
        cellWidth: UInt32,
        cellHeight: UInt32
    ) -> (columns: UInt32, rows: UInt32) {
        var r = rows
        var c = columns
        if r == 0 {
            r = cellHeight == 0 ? 0 : (imageHeight + cellHeight - 1) / cellHeight
        }
        if c == 0 {
            c = cellWidth == 0 ? 0 : (imageWidth + cellWidth - 1) / cellWidth
        }
        return (c, r)
    }

    /// Port of Ghostty `Placement.renderPlacement` (aspect-fit fragment).
    static func renderPlacement(
        placement: Placement,
        gridColumns: UInt32,
        gridRows: UInt32,
        imageWidth: UInt32,
        imageHeight: UInt32,
        cellWidth: UInt32,
        cellHeight: UInt32
    ) -> RenderPlacement? {
        let pGridCols = max(1, gridColumns)
        let pGridRows = max(1, gridRows)
        let imgW = Double(imageWidth)
        let imgH = Double(imageHeight)
        let cellW = Double(cellWidth)
        let cellH = Double(cellHeight)

        let pRowsPx = Double(pGridRows) * cellH
        let pColsPx = Double(pGridCols) * cellW

        let xScale: Double
        let yScale: Double
        var xOffsetPad: Double = 0
        var yOffsetPad: Double = 0
        if imgW * pRowsPx > imgH * pColsPx {
            xScale = pColsPx / max(imgW, 1)
            yScale = xScale
            yOffsetPad = (pRowsPx - imgH * yScale) / 2
        } else {
            yScale = pRowsPx / max(imgH, 1)
            xScale = yScale
            xOffsetPad = (pColsPx - imgW * xScale) / 2
        }

        // Scaled image space including letterbox padding as "offset area".
        let imgScaledXOff = xOffsetPad / xScale
        let imgScaledYOff = yOffsetPad / yScale
        let imgScaledW = imgW + (imgScaledXOff * 2)
        let imgScaledH = imgH + (imgScaledYOff * 2)

        let vpWidth = Double(placement.width)
        let vpHeight = Double(placement.height)
        let vpCol = Double(placement.fragCol)
        let vpRow = Double(placement.fragRow)
        let pGridColsD = Double(pGridCols)
        let pGridRowsD = Double(pGridRows)

        var srcX = imgScaledW * (vpCol / pGridColsD)
        var srcY = imgScaledH * (vpRow / pGridRowsD)
        var srcW = imgScaledW * (vpWidth / pGridColsD)
        var srcH = imgScaledH * (vpHeight / pGridRowsD)

        var destXOff: Double = 0
        var destYOff: Double = 0
        var destW = Double(placement.width) * cellW
        var destH = Double(placement.height) * cellH

        // Vertical letterbox / clip
        if srcY < imgScaledYOff {
            let offset = imgScaledYOff - srcY
            srcH -= offset
            destYOff = offset
            destH -= offset * yScale
            srcY = 0
            if srcH > imgH {
                srcH = imgH
                destH = imgH * yScale
            }
        } else if srcY + srcH > imgScaledH - imgScaledYOff {
            srcY -= imgScaledYOff
            srcH = imgScaledH - imgScaledYOff - srcY
            srcH -= imgScaledYOff
            destH = srcH * yScale
        } else {
            srcY -= imgScaledYOff
        }

        // Horizontal letterbox / clip
        if srcX < imgScaledXOff {
            let offset = imgScaledXOff - srcX
            srcW -= offset
            destXOff = offset
            destW -= offset * xScale
            srcX = 0
            if srcW > imgW {
                srcW = imgW
                destW = imgW * xScale
            }
        } else if srcX + srcW > imgScaledW - imgScaledXOff {
            srcX -= imgScaledXOff
            srcW = imgScaledW - imgScaledXOff - srcX
            srcW -= imgScaledXOff
            destW = srcW * xScale
        } else {
            srcX -= imgScaledXOff
        }

        if srcW <= 0 || srcH <= 0 {
            return nil
        }

        return RenderPlacement(
            offsetX: UInt32(max(0, (destXOff * xScale).rounded())),
            offsetY: UInt32(max(0, (destYOff * yScale).rounded())),
            sourceX: UInt32(max(0, srcX.rounded())),
            sourceY: UInt32(max(0, srcY.rounded())),
            sourceWidth: UInt32(max(0, srcW.rounded())),
            sourceHeight: UInt32(max(0, srcH.rounded())),
            destWidth: UInt32(max(0, destW.rounded())),
            destHeight: UInt32(max(0, destH.rounded()))
        )
    }
}
