import Foundation

/// Symbols for Legacy Computing | U+1FB00…U+1FBFF (+ key supplements).
/// Faithful port of Ghostty `symbols_for_legacy_computing.zig` (+ octants from supplement).
enum LegacySprites {
    static func covers(_ cp: UInt32) -> Bool {
        // Main ranges we implement fully (or nearly so).
        switch cp {
        case 0x1FB00...0x1FB3B,
             0x1FB3C...0x1FB67,
             0x1FB68...0x1FB6F,
             0x1FB70...0x1FB75,
             0x1FB76...0x1FB7B,
             0x1FB7C...0x1FB97,
             0x1FB98, 0x1FB99,
             0x1FB9A...0x1FB9F,
             0x1FBA0...0x1FBAE,
             0x1FBAF,
             0x1FBBD...0x1FBBF,
             0x1FBCE, 0x1FBCF,
             0x1FBD0...0x1FBDF,
             0x1FBE0...0x1FBEF,
             // Octants (supplement)
             0x1CD00...0x1CDE5:
            return true
        default:
            return false
        }
    }

    static func draw(_ cp: UInt32, canvas: SpriteCanvas, metrics: SpriteMetrics) {
        switch cp {
        case 0x1FB00...0x1FB3B: draw1FB00_1FB3B(cp, canvas, metrics)
        case 0x1FB3C...0x1FB67: draw1FB3C_1FB67(cp, canvas, metrics)
        case 0x1FB68...0x1FB6F: draw1FB68_1FB6F(cp, canvas, metrics)
        case 0x1FB70...0x1FB75: draw1FB70_1FB75(cp, canvas, metrics)
        case 0x1FB76...0x1FB7B: draw1FB76_1FB7B(cp, canvas, metrics)
        case 0x1FB7C...0x1FB97: draw1FB7C_1FB97(cp, canvas, metrics)
        case 0x1FB98: draw1FB98(canvas, metrics)
        case 0x1FB99: draw1FB99(canvas, metrics)
        case 0x1FB9A...0x1FB9F: draw1FB9A_1FB9F(cp, canvas, metrics)
        case 0x1FBA0...0x1FBAE: draw1FBA0_1FBAE(cp, canvas, metrics)
        case 0x1FBAF:
            BoxSprites.linesChar(
                metrics, canvas,
                BoxSprites.Lines(up: .heavy, right: .light, down: .heavy, left: .light)
            )
        case 0x1FBBD:
            BoxSprites.lightDiagonalCross(metrics, canvas)
            canvas.invert()
        case 0x1FBBE:
            cornerDiagonalLines(metrics, canvas, tl: false, tr: false, bl: false, br: true)
            canvas.invert()
        case 0x1FBBF:
            cornerDiagonalLines(metrics, canvas, tl: true, tr: true, bl: true, br: true)
            canvas.invert()
        case 0x1FBCE:
            SpriteCommon.block(metrics, canvas, .left, SpriteCommon.twoThirds, 1)
        case 0x1FBCF:
            SpriteCommon.block(metrics, canvas, .left, SpriteCommon.oneThird, 1)
        case 0x1FBD0...0x1FBDF: draw1FBD0_1FBDF(cp, canvas, metrics)
        case 0x1FBE0...0x1FBEF: draw1FBE0_1FBEF(cp, canvas, metrics)
        case 0x1CD00...0x1CDE5: draw1CD00_1CDE5(cp, canvas, metrics)
        default: break
        }
    }

    // MARK: - Sextants U+1FB00–1FB3B

    private static func draw1FB00_1FB3B(
        _ cp: UInt32, _ canvas: SpriteCanvas, _ metrics: SpriteMetrics
    ) {
        // Ghostty: idx = cp - 0x1fb00; sex = @bitCast(idx + idx/0x14 + 1) as u6
        let idx = Int(cp - 0x1FB00)
        let packed = UInt8(truncatingIfNeeded: idx + idx / 0x14 + 1)
        let tl = packed & (1 << 0) != 0
        let tr = packed & (1 << 1) != 0
        let ml = packed & (1 << 2) != 0
        let mr = packed & (1 << 3) != 0
        let bl = packed & (1 << 4) != 0
        let br = packed & (1 << 5) != 0
        if tl { SpriteCommon.fill(metrics, canvas, x0: .zero, x1: .half, y0: .zero, y1: .oneThird) }
        if tr { SpriteCommon.fill(metrics, canvas, x0: .half, x1: .full, y0: .zero, y1: .oneThird) }
        if ml { SpriteCommon.fill(metrics, canvas, x0: .zero, x1: .half, y0: .oneThird, y1: .twoThirds) }
        if mr { SpriteCommon.fill(metrics, canvas, x0: .half, x1: .full, y0: .oneThird, y1: .twoThirds) }
        if bl { SpriteCommon.fill(metrics, canvas, x0: .zero, x1: .half, y0: .twoThirds, y1: .end) }
        if br { SpriteCommon.fill(metrics, canvas, x0: .half, x1: .full, y0: .twoThirds, y1: .end) }
    }

    // MARK: - Smooth mosaics U+1FB3C–1FB67

    private struct SmoothMosaic {
        var tl, ul, ll, bl, bc, br, lr, ur, tr, tc: Bool

        /// Parse a 4×3 pattern string with newlines (15 chars like Ghostty).
        static func from(_ pattern: String) -> SmoothMosaic {
            let p = Array(pattern.utf8)
            func at(_ i: Int) -> Bool { i < p.count && p[i] == UInt8(ascii: "#") }
            // Indices match Ghostty: rows of 3 + newlines at 3,7,11.
            return SmoothMosaic(
                tl: at(0),
                ul: at(4) && !(at(0) && at(8)),
                ll: at(8) && !(at(4) && at(12)),
                bl: at(12),
                bc: at(13) && !(at(12) && at(14)),
                br: at(14),
                lr: at(10) && !(at(14) && at(6)),
                ur: at(6) && !(at(10) && at(2)),
                tr: at(2),
                tc: at(1) && !(at(2) && at(0))
            )
        }
    }

    private static func draw1FB3C_1FB67(
        _ cp: UInt32, _ canvas: SpriteCanvas, _ metrics: SpriteMetrics
    ) {
        let mosaic: SmoothMosaic
        switch cp {
        case 0x1FB3C: mosaic = .from("...\n...\n#..\n##.")
        case 0x1FB3D: mosaic = .from("...\n...\n#\\.\n###")
        case 0x1FB3E: mosaic = .from("...\n#..\n#\\.\n##.")
        case 0x1FB3F: mosaic = .from("...\n#..\n##.\n###")
        case 0x1FB40: mosaic = .from("#..\n#..\n##.\n##.")
        case 0x1FB41: mosaic = .from("/##\n###\n###\n###")
        case 0x1FB42: mosaic = .from("./#\n###\n###\n###")
        case 0x1FB43: mosaic = .from(".##\n.##\n###\n###")
        case 0x1FB44: mosaic = .from("..#\n.##\n###\n###")
        case 0x1FB45: mosaic = .from(".##\n.##\n.##\n###")
        case 0x1FB46: mosaic = .from("...\n./#\n###\n###")
        case 0x1FB47: mosaic = .from("...\n...\n..#\n.##")
        case 0x1FB48: mosaic = .from("...\n...\n./#\n###")
        case 0x1FB49: mosaic = .from("...\n..#\n./#\n.##")
        case 0x1FB4A: mosaic = .from("...\n..#\n.##\n###")
        case 0x1FB4B: mosaic = .from("..#\n..#\n.##\n.##")
        case 0x1FB4C: mosaic = .from("##\\\n###\n###\n###")
        case 0x1FB4D: mosaic = .from("#\\.\n###\n###\n###")
        case 0x1FB4E: mosaic = .from("##.\n##.\n###\n###")
        case 0x1FB4F: mosaic = .from("#..\n##.\n###\n###")
        case 0x1FB50: mosaic = .from("##.\n##.\n##.\n###")
        case 0x1FB51: mosaic = .from("...\n#\\.\n###\n###")
        case 0x1FB52: mosaic = .from("###\n###\n###\n\\##")
        case 0x1FB53: mosaic = .from("###\n###\n###\n.\\#")
        case 0x1FB54: mosaic = .from("###\n###\n.##\n.##")
        case 0x1FB55: mosaic = .from("###\n###\n.##\n..#")
        case 0x1FB56: mosaic = .from("###\n.##\n.##\n.##")
        case 0x1FB57: mosaic = .from("##.\n#..\n...\n...")
        case 0x1FB58: mosaic = .from("###\n#/.\n...\n...")
        case 0x1FB59: mosaic = .from("##.\n#/.\n#..\n...")
        case 0x1FB5A: mosaic = .from("###\n##.\n#..\n...")
        case 0x1FB5B: mosaic = .from("##.\n##.\n#..\n#..")
        case 0x1FB5C: mosaic = .from("###\n###\n#/.\n...")
        case 0x1FB5D: mosaic = .from("###\n###\n###\n##/")
        case 0x1FB5E: mosaic = .from("###\n###\n###\n#/.")
        case 0x1FB5F: mosaic = .from("###\n###\n##.\n##.")
        case 0x1FB60: mosaic = .from("###\n###\n##.\n#..")
        case 0x1FB61: mosaic = .from("###\n##.\n##.\n##.")
        case 0x1FB62: mosaic = .from(".##\n..#\n...\n...")
        case 0x1FB63: mosaic = .from("###\n.\\#\n...\n...")
        case 0x1FB64: mosaic = .from(".##\n.\\#\n..#\n...")
        case 0x1FB65: mosaic = .from("###\n.##\n..#\n...")
        case 0x1FB66: mosaic = .from(".##\n.##\n..#\n..#")
        case 0x1FB67: mosaic = .from("###\n###\n.\\#\n...")
        default: return
        }

        let top = 0.0
        let upper = SpriteCommon.Fraction.oneThird.float(metrics.cellHeight)
        let lower = SpriteCommon.Fraction.twoThirds.float(metrics.cellHeight)
        let bottom = Double(metrics.cellHeight)
        let left = 0.0
        let center = SpriteCommon.Fraction.half.float(metrics.cellWidth)
        let right = Double(metrics.cellWidth)

        var pts: [SpriteCanvas.Point] = []
        if mosaic.tl { pts.append(.init(x: left, y: top)) }
        if mosaic.ul { pts.append(.init(x: left, y: upper)) }
        if mosaic.ll { pts.append(.init(x: left, y: lower)) }
        if mosaic.bl { pts.append(.init(x: left, y: bottom)) }
        if mosaic.bc { pts.append(.init(x: center, y: bottom)) }
        if mosaic.br { pts.append(.init(x: right, y: bottom)) }
        if mosaic.lr { pts.append(.init(x: right, y: lower)) }
        if mosaic.ur { pts.append(.init(x: right, y: upper)) }
        if mosaic.tr { pts.append(.init(x: right, y: top)) }
        if mosaic.tc { pts.append(.init(x: center, y: top)) }
        canvas.fillPolygon(pts, value: 255)
    }

    // MARK: - Edge triangles U+1FB68–1FB6F

    private static func draw1FB68_1FB6F(
        _ cp: UInt32, _ canvas: SpriteCanvas, _ metrics: SpriteMetrics
    ) {
        switch cp {
        case 0x1FB68:
            edgeTriangle(metrics, canvas, .left)
            canvas.invert()
        case 0x1FB69:
            edgeTriangle(metrics, canvas, .top)
            canvas.invert()
        case 0x1FB6A:
            edgeTriangle(metrics, canvas, .right)
            canvas.invert()
        case 0x1FB6B:
            edgeTriangle(metrics, canvas, .bottom)
            canvas.invert()
        case 0x1FB6C: edgeTriangle(metrics, canvas, .left)
        case 0x1FB6D: edgeTriangle(metrics, canvas, .top)
        case 0x1FB6E: edgeTriangle(metrics, canvas, .right)
        case 0x1FB6F: edgeTriangle(metrics, canvas, .bottom)
        default: break
        }
    }

    // MARK: - Eighth blocks

    private static func draw1FB70_1FB75(
        _ cp: UInt32, _ canvas: SpriteCanvas, _ metrics: SpriteMetrics
    ) {
        let n = Int(cp + 1 - 0x1FB70)
        guard n >= 0, n + 1 < SpriteCommon.Fraction.eighths.count else { return }
        SpriteCommon.fill(
            metrics, canvas,
            x0: SpriteCommon.Fraction.eighths[n],
            x1: SpriteCommon.Fraction.eighths[n + 1],
            y0: .top, y1: .bottom
        )
    }

    private static func draw1FB76_1FB7B(
        _ cp: UInt32, _ canvas: SpriteCanvas, _ metrics: SpriteMetrics
    ) {
        let n = Int(cp + 1 - 0x1FB76)
        guard n >= 0, n + 1 < SpriteCommon.Fraction.eighths.count else { return }
        SpriteCommon.fill(
            metrics, canvas,
            x0: .left, x1: .right,
            y0: SpriteCommon.Fraction.eighths[n],
            y1: SpriteCommon.Fraction.eighths[n + 1]
        )
    }

    private static func draw1FB7C_1FB97(
        _ cp: UInt32, _ canvas: SpriteCanvas, _ metrics: SpriteMetrics
    ) {
        let e = SpriteCommon.oneEighth
        let q = SpriteCommon.oneQuarter
        let te = SpriteCommon.threeEighths
        let h = SpriteCommon.half
        let fe = SpriteCommon.fiveEighths
        let tq = SpriteCommon.threeQuarters
        let se = SpriteCommon.sevenEighths

        switch cp {
        case 0x1FB7C:
            SpriteCommon.block(metrics, canvas, .left, e, 1)
            SpriteCommon.block(metrics, canvas, .lower, 1, e)
        case 0x1FB7D:
            SpriteCommon.block(metrics, canvas, .left, e, 1)
            SpriteCommon.block(metrics, canvas, .upper, 1, e)
        case 0x1FB7E:
            SpriteCommon.block(metrics, canvas, .right, e, 1)
            SpriteCommon.block(metrics, canvas, .upper, 1, e)
        case 0x1FB7F:
            SpriteCommon.block(metrics, canvas, .right, e, 1)
            SpriteCommon.block(metrics, canvas, .lower, 1, e)
        case 0x1FB80:
            SpriteCommon.block(metrics, canvas, .upper, 1, e)
            SpriteCommon.block(metrics, canvas, .lower, 1, e)
        case 0x1FB81:
            // Horizontal one-eighth blocks at positions 1,3,5,8 (Ghostty uses 0x1fb74+n)
            draw1FB76_1FB7B(0x1FB74 + 1, canvas, metrics)
            draw1FB76_1FB7B(0x1FB74 + 3, canvas, metrics)
            draw1FB76_1FB7B(0x1FB74 + 5, canvas, metrics)
            draw1FB76_1FB7B(0x1FB74 + 8, canvas, metrics)
        case 0x1FB82: SpriteCommon.block(metrics, canvas, .upper, 1, q)
        case 0x1FB83: SpriteCommon.block(metrics, canvas, .upper, 1, te)
        case 0x1FB84: SpriteCommon.block(metrics, canvas, .upper, 1, fe)
        case 0x1FB85: SpriteCommon.block(metrics, canvas, .upper, 1, tq)
        case 0x1FB86: SpriteCommon.block(metrics, canvas, .upper, 1, se)
        case 0x1FB87: SpriteCommon.block(metrics, canvas, .right, q, 1)
        case 0x1FB88: SpriteCommon.block(metrics, canvas, .right, te, 1)
        case 0x1FB89: SpriteCommon.block(metrics, canvas, .right, fe, 1)
        case 0x1FB8A: SpriteCommon.block(metrics, canvas, .right, tq, 1)
        case 0x1FB8B: SpriteCommon.block(metrics, canvas, .right, se, 1)
        case 0x1FB8C:
            SpriteCommon.blockShade(metrics, canvas, .left, h, 1, .medium)
        case 0x1FB8D:
            SpriteCommon.blockShade(metrics, canvas, .right, h, 1, .medium)
        case 0x1FB8E:
            SpriteCommon.blockShade(metrics, canvas, .upper, 1, h, .medium)
        case 0x1FB8F:
            SpriteCommon.blockShade(metrics, canvas, .lower, 1, h, .medium)
        case 0x1FB90:
            SpriteCommon.fullBlockShade(metrics, canvas, .medium)
        case 0x1FB91:
            SpriteCommon.fullBlockShade(metrics, canvas, .medium)
            SpriteCommon.block(metrics, canvas, .upper, 1, h)
        case 0x1FB92:
            SpriteCommon.fullBlockShade(metrics, canvas, .medium)
            SpriteCommon.block(metrics, canvas, .lower, 1, h)
        case 0x1FB93:
            break // unallocated
        case 0x1FB94:
            SpriteCommon.fullBlockShade(metrics, canvas, .medium)
            SpriteCommon.block(metrics, canvas, .right, h, 1)
        case 0x1FB95: checkerboardFill(metrics, canvas, parity: 0)
        case 0x1FB96: checkerboardFill(metrics, canvas, parity: 1)
        case 0x1FB97:
            let w = metrics.cellWidth
            let hgt = metrics.cellHeight
            canvas.box(x0: 0, y0: hgt / 4, x1: w, y1: 2 * hgt / 4, value: 255)
            canvas.box(x0: 0, y0: 3 * hgt / 4, x1: w, y1: hgt, value: 255)
        default: break
        }
    }

    // MARK: - Diagonal fills 1FB98 / 1FB99

    private static func draw1FB98(_ canvas: SpriteCanvas, _ metrics: SpriteMetrics) {
        let thickPx = SpriteCommon.Thickness.light.height(base: metrics.boxThickness)
        let lineCount = max(1, metrics.cellWidth / (2 * thickPx))
        let fw = Double(metrics.cellWidth)
        let fh = Double(metrics.cellHeight)
        let floatThick = Double(thickPx)
        let stride = (fw / Double(lineCount)).rounded()
        for _i in 0..<(lineCount * 2 + 1) {
            let i = _i - lineCount
            let topX = Double(i) * stride
            let bottomX = fw + topX
            canvas.strokeLine(
                x0: topX, y0: 0, x1: bottomX, y1: fh,
                thickness: floatThick, value: 255
            )
        }
    }

    private static func draw1FB99(_ canvas: SpriteCanvas, _ metrics: SpriteMetrics) {
        let thickPx = SpriteCommon.Thickness.light.height(base: metrics.boxThickness)
        let lineCount = max(1, metrics.cellWidth / (2 * thickPx))
        let fw = Double(metrics.cellWidth)
        let fh = Double(metrics.cellHeight)
        let floatThick = Double(thickPx)
        let stride = (fw / Double(lineCount)).rounded()
        for _i in 0..<(lineCount * 2 + 1) {
            let i = _i - lineCount
            let bottomX = Double(i) * stride
            let topX = fw + bottomX
            canvas.strokeLine(
                x0: topX, y0: 0, x1: bottomX, y1: fh,
                thickness: floatThick, value: 255
            )
        }
    }

    // MARK: - 1FB9A–1FB9F

    private static func draw1FB9A_1FB9F(
        _ cp: UInt32, _ canvas: SpriteCanvas, _ metrics: SpriteMetrics
    ) {
        switch cp {
        case 0x1FB9A:
            edgeTriangle(metrics, canvas, .top)
            edgeTriangle(metrics, canvas, .bottom)
        case 0x1FB9B:
            edgeTriangle(metrics, canvas, .left)
            edgeTriangle(metrics, canvas, .right)
        case 0x1FB9C: cornerTriangleShade(metrics, canvas, .tl, .medium)
        case 0x1FB9D: cornerTriangleShade(metrics, canvas, .tr, .medium)
        case 0x1FB9E: cornerTriangleShade(metrics, canvas, .br, .medium)
        case 0x1FB9F: cornerTriangleShade(metrics, canvas, .bl, .medium)
        default: break
        }
    }

    // MARK: - Corner diagonals 1FBA0–1FBAE

    private static func draw1FBA0_1FBAE(
        _ cp: UInt32, _ canvas: SpriteCanvas, _ metrics: SpriteMetrics
    ) {
        switch cp {
        case 0x1FBA0: cornerDiagonalLines(metrics, canvas, tl: true, tr: false, bl: false, br: false)
        case 0x1FBA1: cornerDiagonalLines(metrics, canvas, tl: false, tr: true, bl: false, br: false)
        case 0x1FBA2: cornerDiagonalLines(metrics, canvas, tl: false, tr: false, bl: true, br: false)
        case 0x1FBA3: cornerDiagonalLines(metrics, canvas, tl: false, tr: false, bl: false, br: true)
        case 0x1FBA4: cornerDiagonalLines(metrics, canvas, tl: true, tr: false, bl: true, br: false)
        case 0x1FBA5: cornerDiagonalLines(metrics, canvas, tl: false, tr: true, bl: false, br: true)
        case 0x1FBA6: cornerDiagonalLines(metrics, canvas, tl: false, tr: false, bl: true, br: true)
        case 0x1FBA7: cornerDiagonalLines(metrics, canvas, tl: true, tr: true, bl: false, br: false)
        case 0x1FBA8: cornerDiagonalLines(metrics, canvas, tl: true, tr: false, bl: false, br: true)
        case 0x1FBA9: cornerDiagonalLines(metrics, canvas, tl: false, tr: true, bl: true, br: false)
        case 0x1FBAA: cornerDiagonalLines(metrics, canvas, tl: false, tr: true, bl: true, br: true)
        case 0x1FBAB: cornerDiagonalLines(metrics, canvas, tl: true, tr: false, bl: true, br: true)
        case 0x1FBAC: cornerDiagonalLines(metrics, canvas, tl: true, tr: true, bl: false, br: true)
        case 0x1FBAD: cornerDiagonalLines(metrics, canvas, tl: true, tr: true, bl: true, br: false)
        case 0x1FBAE: cornerDiagonalLines(metrics, canvas, tl: true, tr: true, bl: true, br: true)
        default: break
        }
    }

    // MARK: - Cell diagonals 1FBD0–1FBDF

    private static func draw1FBD0_1FBDF(
        _ cp: UInt32, _ canvas: SpriteCanvas, _ metrics: SpriteMetrics
    ) {
        typealias A = SpriteCommon.Alignment
        switch cp {
        case 0x1FBD0: cellDiagonal(metrics, canvas, from: .middleRight, to: .lowerLeft)
        case 0x1FBD1: cellDiagonal(metrics, canvas, from: .upperRight, to: .middleLeft)
        case 0x1FBD2: cellDiagonal(metrics, canvas, from: .upperLeft, to: .middleRight)
        case 0x1FBD3: cellDiagonal(metrics, canvas, from: .middleLeft, to: .lowerRight)
        case 0x1FBD4: cellDiagonal(metrics, canvas, from: .upperLeft, to: .lowerCenter)
        case 0x1FBD5: cellDiagonal(metrics, canvas, from: .upperCenter, to: .lowerRight)
        case 0x1FBD6: cellDiagonal(metrics, canvas, from: .upperRight, to: .lowerCenter)
        case 0x1FBD7: cellDiagonal(metrics, canvas, from: .upperCenter, to: .lowerLeft)
        case 0x1FBD8:
            cellDiagonal(metrics, canvas, from: .upperLeft, to: .middleCenter)
            cellDiagonal(metrics, canvas, from: .middleCenter, to: .upperRight)
        case 0x1FBD9:
            cellDiagonal(metrics, canvas, from: .upperRight, to: .middleCenter)
            cellDiagonal(metrics, canvas, from: .middleCenter, to: .lowerRight)
        case 0x1FBDA:
            cellDiagonal(metrics, canvas, from: .lowerLeft, to: .middleCenter)
            cellDiagonal(metrics, canvas, from: .middleCenter, to: .lowerRight)
        case 0x1FBDB:
            cellDiagonal(metrics, canvas, from: .upperLeft, to: .middleCenter)
            cellDiagonal(metrics, canvas, from: .middleCenter, to: .lowerLeft)
        case 0x1FBDC:
            cellDiagonal(metrics, canvas, from: .upperLeft, to: .lowerCenter)
            cellDiagonal(metrics, canvas, from: .lowerCenter, to: .upperRight)
        case 0x1FBDD:
            cellDiagonal(metrics, canvas, from: .upperRight, to: .middleLeft)
            cellDiagonal(metrics, canvas, from: .middleLeft, to: .lowerRight)
        case 0x1FBDE:
            cellDiagonal(metrics, canvas, from: .lowerLeft, to: .upperCenter)
            cellDiagonal(metrics, canvas, from: .upperCenter, to: .lowerRight)
        case 0x1FBDF:
            cellDiagonal(metrics, canvas, from: .upperLeft, to: .middleRight)
            cellDiagonal(metrics, canvas, from: .middleRight, to: .lowerLeft)
        default: break
        }
        _ = A.self
    }

    // MARK: - Circles / half blocks 1FBE0–1FBEF

    private static func draw1FBE0_1FBEF(
        _ cp: UInt32, _ canvas: SpriteCanvas, _ metrics: SpriteMetrics
    ) {
        switch cp {
        case 0x1FBE0: circle(metrics, canvas, .top, filled: false)
        case 0x1FBE1: circle(metrics, canvas, .right, filled: false)
        case 0x1FBE2: circle(metrics, canvas, .bottom, filled: false)
        case 0x1FBE3: circle(metrics, canvas, .left, filled: false)
        case 0x1FBE4: SpriteCommon.block(metrics, canvas, .upperCenter, 0.5, 0.5)
        case 0x1FBE5: SpriteCommon.block(metrics, canvas, .lowerCenter, 0.5, 0.5)
        case 0x1FBE6: SpriteCommon.block(metrics, canvas, .middleLeft, 0.5, 0.5)
        case 0x1FBE7: SpriteCommon.block(metrics, canvas, .middleRight, 0.5, 0.5)
        case 0x1FBE8: circle(metrics, canvas, .top, filled: true)
        case 0x1FBE9: circle(metrics, canvas, .right, filled: true)
        case 0x1FBEA: circle(metrics, canvas, .bottom, filled: true)
        case 0x1FBEB: circle(metrics, canvas, .left, filled: true)
        case 0x1FBEC: circle(metrics, canvas, .topRight, filled: true)
        case 0x1FBED: circle(metrics, canvas, .bottomLeft, filled: true)
        case 0x1FBEE: circle(metrics, canvas, .bottomRight, filled: true)
        case 0x1FBEF: circle(metrics, canvas, .topLeft, filled: true)
        default: break
        }
    }

    // MARK: - Octants U+1CD00–1CDE5

    private static func draw1CD00_1CDE5(
        _ cp: UInt32, _ canvas: SpriteCanvas, _ metrics: SpriteMetrics
    ) {
        let idx = Int(cp - 0x1CD00)
        guard idx >= 0, idx < Self.octantMasks.count else { return }
        let mask = Self.octantMasks[idx]
        // bits 1…8 → positions in 2×4 grid
        if mask & (1 << 0) != 0 { // 1
            SpriteCommon.fill(metrics, canvas, x0: .zero, x1: .half, y0: .zero, y1: .oneQuarter)
        }
        if mask & (1 << 1) != 0 { // 2
            SpriteCommon.fill(metrics, canvas, x0: .half, x1: .full, y0: .zero, y1: .oneQuarter)
        }
        if mask & (1 << 2) != 0 { // 3
            SpriteCommon.fill(metrics, canvas, x0: .zero, x1: .half, y0: .oneQuarter, y1: .twoQuarters)
        }
        if mask & (1 << 3) != 0 { // 4
            SpriteCommon.fill(metrics, canvas, x0: .half, x1: .full, y0: .oneQuarter, y1: .twoQuarters)
        }
        if mask & (1 << 4) != 0 { // 5
            SpriteCommon.fill(metrics, canvas, x0: .zero, x1: .half, y0: .twoQuarters, y1: .threeQuarters)
        }
        if mask & (1 << 5) != 0 { // 6
            SpriteCommon.fill(metrics, canvas, x0: .half, x1: .full, y0: .twoQuarters, y1: .threeQuarters)
        }
        if mask & (1 << 6) != 0 { // 7
            SpriteCommon.fill(metrics, canvas, x0: .zero, x1: .half, y0: .threeQuarters, y1: .end)
        }
        if mask & (1 << 7) != 0 { // 8
            SpriteCommon.fill(metrics, canvas, x0: .half, x1: .full, y0: .threeQuarters, y1: .end)
        }
    }

    /// Precomputed from Ghostty `octants.txt` (BLOCK OCTANT-digits).
    private static let octantMasks: [UInt8] = {
        // Generated offline from octants.txt lines; bit i-1 set for digit i.
        let lines = """
        3
        23
        123
        4
        14
        124
        34
        134
        234
        5
        15
        25
        125
        135
        235
        1235
        45
        145
        245
        1245
        345
        1345
        2345
        12345
        6
        16
        26
        126
        36
        136
        236
        1236
        146
        246
        1246
        346
        1346
        2346
        12346
        56
        156
        256
        1256
        356
        1356
        2356
        12356
        456
        1456
        2456
        12456
        3456
        13456
        23456
        17
        27
        127
        37
        137
        237
        1237
        47
        147
        247
        1247
        347
        1347
        2347
        12347
        157
        257
        1257
        357
        2357
        12357
        457
        1457
        12457
        3457
        13457
        23457
        67
        167
        267
        1267
        367
        1367
        2367
        12367
        467
        1467
        2467
        12467
        3467
        13467
        23467
        123467
        567
        1567
        2567
        12567
        3567
        13567
        23567
        123567
        4567
        14567
        24567
        124567
        34567
        134567
        234567
        1234567
        18
        28
        128
        38
        138
        238
        1238
        48
        148
        248
        1248
        348
        1348
        2348
        12348
        58
        158
        258
        1258
        358
        1358
        2358
        12358
        458
        1458
        2458
        12458
        3458
        13458
        23458
        123458
        168
        268
        1268
        368
        2368
        12368
        468
        1468
        12468
        3468
        13468
        23468
        568
        1568
        2568
        12568
        3568
        13568
        23568
        123568
        4568
        14568
        24568
        124568
        34568
        134568
        234568
        1234568
        178
        278
        1278
        378
        1378
        2378
        12378
        478
        1478
        2478
        12478
        3478
        13478
        23478
        123478
        578
        1578
        2578
        12578
        3578
        13578
        23578
        123578
        4578
        14578
        24578
        124578
        34578
        134578
        234578
        1234578
        678
        1678
        2678
        12678
        3678
        13678
        23678
        123678
        4678
        14678
        24678
        124678
        34678
        134678
        234678
        1234678
        15678
        25678
        125678
        35678
        235678
        1235678
        45678
        145678
        1245678
        1345678
        2345678
        """
        return lines.split(separator: "\n").map { digits -> UInt8 in
            var m: UInt8 = 0
            for ch in digits {
                if let d = ch.wholeNumberValue, d >= 1, d <= 8 {
                    m |= 1 << (d - 1)
                }
            }
            return m
        }
    }()

    // MARK: - Shared helpers

    private static func edgeTriangle(
        _ metrics: SpriteMetrics,
        _ canvas: SpriteCanvas,
        _ edge: SpriteCommon.Edge
    ) {
        let upper = 0.0
        let middle = (Double(metrics.cellHeight) / 2).rounded()
        let lower = Double(metrics.cellHeight)
        let left = 0.0
        let center = (Double(metrics.cellWidth) / 2).rounded()
        let right = Double(metrics.cellWidth)

        let (x0, y0, x1, y1): (Double, Double, Double, Double)
        switch edge {
        case .top: (x0, y0, x1, y1) = (right, upper, left, upper)
        case .left: (x0, y0, x1, y1) = (left, upper, left, lower)
        case .bottom: (x0, y0, x1, y1) = (left, lower, right, lower)
        case .right: (x0, y0, x1, y1) = (right, lower, right, upper)
        }
        canvas.fillTriangle(
            p0: .init(x: center, y: middle),
            p1: .init(x: x0, y: y0),
            p2: .init(x: x1, y: y1),
            value: 255
        )
    }

    private static func cornerDiagonalLines(
        _ metrics: SpriteMetrics,
        _ canvas: SpriteCanvas,
        tl: Bool, tr: Bool, bl: Bool, br: Bool
    ) {
        let thickPx = SpriteCommon.Thickness.light.height(base: metrics.boxThickness)
        let fw = Double(metrics.cellWidth)
        let fh = Double(metrics.cellHeight)
        let floatThick = Double(thickPx)
        let centerX = Double(metrics.cellWidth / 2 + metrics.cellWidth % 2)
        let centerY = Double(metrics.cellHeight / 2 + metrics.cellHeight % 2)

        if tl {
            canvas.strokeLine(x0: centerX, y0: 0, x1: 0, y1: centerY, thickness: floatThick)
        }
        if tr {
            canvas.strokeLine(x0: centerX, y0: 0, x1: fw, y1: centerY, thickness: floatThick)
        }
        if bl {
            canvas.strokeLine(x0: centerX, y0: fh, x1: 0, y1: centerY, thickness: floatThick)
        }
        if br {
            canvas.strokeLine(x0: centerX, y0: fh, x1: fw, y1: centerY, thickness: floatThick)
        }
    }

    private static func cellDiagonal(
        _ metrics: SpriteMetrics,
        _ canvas: SpriteCanvas,
        from: SpriteCommon.Alignment,
        to: SpriteCommon.Alignment
    ) {
        let fw = Double(metrics.cellWidth)
        let fh = Double(metrics.cellHeight)
        func x(_ a: SpriteCommon.Alignment) -> Double {
            switch a.horizontal {
            case .left: return 0
            case .right: return fw
            case .center: return fw / 2
            }
        }
        func y(_ a: SpriteCommon.Alignment) -> Double {
            switch a.vertical {
            case .top: return 0
            case .bottom: return fh
            case .middle: return fh / 2
            }
        }
        let thick = Double(SpriteCommon.Thickness.light.height(base: metrics.boxThickness))
        canvas.strokeLine(x0: x(from), y0: y(from), x1: x(to), y1: y(to), thickness: thick)
    }

    private static func cornerTriangleShade(
        _ metrics: SpriteMetrics,
        _ canvas: SpriteCanvas,
        _ corner: SpriteCommon.Corner,
        _ shade: SpriteCommon.Shade
    ) {
        let w = Double(metrics.cellWidth)
        let h = Double(metrics.cellHeight)
        let pts: [SpriteCanvas.Point]
        switch corner {
        case .tl: pts = [.init(x: 0, y: 0), .init(x: 0, y: h), .init(x: w, y: 0)]
        case .tr: pts = [.init(x: 0, y: 0), .init(x: w, y: h), .init(x: w, y: 0)]
        case .bl: pts = [.init(x: 0, y: 0), .init(x: 0, y: h), .init(x: w, y: h)]
        case .br: pts = [.init(x: 0, y: h), .init(x: w, y: h), .init(x: w, y: 0)]
        }
        canvas.fillPolygon(pts, value: shade.rawValue)
    }

    private static func checkerboardFill(
        _ metrics: SpriteMetrics,
        _ canvas: SpriteCanvas,
        parity: Int
    ) {
        let fw = Double(metrics.cellWidth)
        let fh = Double(metrics.cellHeight)
        let xSize = 4
        let ySize = max(1, Int((4 * (fh / fw)).rounded()))
        for x in 0..<xSize {
            let x0 = (metrics.cellWidth * x) / xSize
            let x1 = (metrics.cellWidth * (x + 1)) / xSize
            for y in 0..<ySize {
                let y0 = (metrics.cellHeight * y) / ySize
                let y1 = (metrics.cellHeight * (y + 1)) / ySize
                if (x + y) % 2 == parity {
                    canvas.fillRect(x: x0, y: y0, w: max(0, x1 - x0), h: max(0, y1 - y0), value: 255)
                }
            }
        }
    }

    private static func circle(
        _ metrics: SpriteMetrics,
        _ canvas: SpriteCanvas,
        _ position: SpriteCommon.Alignment,
        filled: Bool
    ) {
        let fw = Double(metrics.cellWidth)
        let fh = Double(metrics.cellHeight)
        let x: Double
        switch position.horizontal {
        case .left: x = 0
        case .right: x = fw
        case .center: x = fw / 2
        }
        let y: Double
        switch position.vertical {
        case .top: y = 0
        case .bottom: y = fh
        case .middle: y = fh / 2
        }
        let r = 0.5 * min(fw, fh)
        let thick = Double(SpriteCommon.Thickness.light.height(base: metrics.boxThickness))
        if filled {
            canvas.fillCircle(cx: x, cy: y, r: r, value: 255)
        } else {
            canvas.strokeCircle(cx: x, cy: y, r: max(0.5, r - thick / 2), thickness: thick, value: 255)
        }
    }
}
