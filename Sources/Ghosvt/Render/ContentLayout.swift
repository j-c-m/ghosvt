import CoreGraphics
import Foundation

/// Centers a terminal content rect inside the drawable, capping max width/height.
/// Wider screens (e.g. 21:9) get side bars of background color.
enum ContentLayout {
    /// Content rect in the same unit space as `size` (points or pixels), top-left origin.
    /// - Parameter maxAspect: Maximum width/height (e.g. `1.5` for 3:2).
    static func contentRect(in size: CGSize, maxAspect: CGFloat) -> CGRect {
        let w = size.width
        let h = size.height
        guard w > 0, h > 0, maxAspect > 0 else { return .zero }

        var contentW = w
        let contentH = h
        if contentW / contentH > maxAspect {
            contentW = contentH * maxAspect
        }
        // Only cap *maximum* aspect (width/height); portrait stays full-bleed.

        let x = (w - contentW) * 0.5
        let y = (h - contentH) * 0.5
        return CGRect(x: x, y: y, width: contentW, height: contentH)
    }
}
