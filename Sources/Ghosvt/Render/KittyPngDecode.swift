import CGhosttyVT
import CoreGraphics
import Foundation
import ImageIO

/// Process-global PNG decoder for Kitty graphics (`GHOSTTY_SYS_OPT_DECODE_PNG`).
///
/// ImageIO → RGBA8. Pixel buffer is allocated with `ghostty_alloc`; libghostty
/// owns and frees it. Must be installed once at startup before any terminal.
enum KittyPngDecode {
    /// Install the PNG callback. Safe to call once at launch.
    static func install() {
        let fn: GhosttySysDecodePngFn = decodePng
        // C API takes a function pointer as `const void *`.
        let raw = unsafeBitCast(fn, to: UnsafeRawPointer.self)
        let r = ghostty_sys_set(GHOSTTY_SYS_OPT_DECODE_PNG, raw)
        if r != GHOSTTY_SUCCESS {
            fputs("ghosvt: failed to install Kitty PNG decoder (\(r.rawValue))\n", stderr)
        } else {
            fputs("ghosvt: Kitty PNG decoder (ImageIO) installed\n", stderr)
        }
    }

    /// Clear the process-global callback (tests / teardown).
    static func uninstall() {
        _ = ghostty_sys_set(GHOSTTY_SYS_OPT_DECODE_PNG, nil)
    }
}

/// C ABI callback: decode PNG bytes into RGBA via ImageIO.
private func decodePng(
    _ userdata: UnsafeMutableRawPointer?,
    _ allocator: UnsafePointer<GhosttyAllocator>?,
    _ data: UnsafePointer<UInt8>?,
    _ dataLen: Int,
    _ out: UnsafeMutablePointer<GhosttySysImage>?
) -> Bool {
    _ = userdata
    guard let data, dataLen > 0, let out else { return false }

    let cfData = CFDataCreate(kCFAllocatorDefault, data, dataLen)
    guard let cfData else { return false }
    guard let source = CGImageSourceCreateWithData(cfData, nil) else { return false }
    guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }

    let width = cgImage.width
    let height = cgImage.height
    guard width > 0, height > 0, width <= 16_384, height <= 16_384 else { return false }

    let bytesPerRow = width * 4
    let byteCount = bytesPerRow * height
    guard let pixels = ghostty_alloc(allocator, byteCount) else { return false }

    // Straight RGBA, top-left origin (match Kitty storage / Metal upload).
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo =
        CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.last.rawValue
    guard let ctx = CGContext(
        data: pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else {
        ghostty_free(allocator, pixels, byteCount)
        return false
    }

    ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
    // CGContext is bottom-left; flip so row 0 is the top of the image.
    ctx.translateBy(x: 0, y: CGFloat(height))
    ctx.scaleBy(x: 1, y: -1)
    ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

    out.pointee.width = UInt32(width)
    out.pointee.height = UInt32(height)
    out.pointee.data = pixels
    out.pointee.data_len = byteCount
    return true
}
