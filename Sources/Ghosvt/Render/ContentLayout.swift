import CoreGraphics
import Foundation

/// Centers a terminal content rect inside the drawable, capping aspect ratio at 16:10.
/// Wider screens (e.g. 21:9) get side bars of background color.
enum ContentLayout {
    /// Maximum width/height for the terminal grid area.
    static let maxAspect: CGFloat = 16.0 / 10.0

    /// Content rect in the same unit space as `size` (points or pixels), top-left origin.
    static func contentRect(in size: CGSize, maxAspect: CGFloat = maxAspect) -> CGRect {
        let w = size.width
        let h = size.height
        guard w > 0, h > 0 else { return .zero }

        var contentW = w
        let contentH = h
        if contentW / contentH > maxAspect {
            contentW = contentH * maxAspect
        }
        // If somehow taller than 16:9 would require letterboxing top/bottom,
        // we only cap *maximum* aspect (width/height), so portrait stays full-bleed.

        let x = (w - contentW) * 0.5
        let y = (h - contentH) * 0.5
        return CGRect(x: x, y: y, width: contentW, height: contentH)
    }
}
