import Foundation

/// Per-cell GPU instance — explicit float layout matching Metal `CellInstance`.
/// Avoids Swift SIMD alignment surprises when writing into MTLBuffer.
struct CellInstance {
    // origin.xy, size.xy
    var ox: Float, oy: Float, sx: Float, sy: Float
    // uv u0,v0,u1,v1
    var u0: Float, v0: Float, u1: Float, v1: Float
    // fg rgba
    var fr: Float, fg: Float, fb: Float, fa: Float
    // bg rgba
    var br: Float, bg: Float, bb: Float, ba: Float

    static let floatCount = 16
    static var stride: Int { floatCount * MemoryLayout<Float>.size } // 64

    static func make(
        originX: Float, originY: Float,
        width: Float, height: Float,
        u0: Float, v0: Float, u1: Float, v1: Float,
        fr: Float, fg: Float, fb: Float, fa: Float,
        br: Float, bg: Float, bb: Float, ba: Float
    ) -> CellInstance {
        CellInstance(
            ox: originX, oy: originY, sx: width, sy: height,
            u0: u0, v0: v0, u1: u1, v1: v1,
            fr: fr, fg: fg, fb: fb, fa: fa,
            br: br, bg: bg, bb: bb, ba: ba
        )
    }

    func write(to buf: UnsafeMutablePointer<Float>, at index: Int) {
        let o = index * Self.floatCount
        buf[o + 0] = ox; buf[o + 1] = oy; buf[o + 2] = sx; buf[o + 3] = sy
        buf[o + 4] = u0; buf[o + 5] = v0; buf[o + 6] = u1; buf[o + 7] = v1
        buf[o + 8] = fr; buf[o + 9] = fg; buf[o + 10] = fb; buf[o + 11] = fa
        buf[o + 12] = br; buf[o + 13] = bg; buf[o + 14] = bb; buf[o + 15] = ba
    }
}

struct FrameUniforms {
    var viewportX: Float
    var viewportY: Float
    var _pad0: Float = 0
    var _pad1: Float = 0

    static var stride: Int { 4 * MemoryLayout<Float>.size }
}
