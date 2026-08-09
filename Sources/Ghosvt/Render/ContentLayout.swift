import CoreGraphics
import Foundation

/// Centers a terminal content rect inside the drawable, capping max width/height.
/// Wider screens (e.g. 21:9) get side letterbox bars cleared to the live terminal /
/// FS TUI background (see `TerminalRenderer.letterboxBackground`).
enum ContentLayout {
    /// Content rect in the same unit space as `size` (points or pixels), top-left origin.
    /// - Parameter maxAspect: Maximum width/height (e.g. `1.5` for 3:2).
    /// - Parameter snapPixels: Round origin/size to whole units (device pixels when `size` is drawable).
    static func contentRect(in size: CGSize, maxAspect: CGFloat, snapPixels: Bool = false) -> CGRect {
        let w = size.width
        let h = size.height
        guard w > 0, h > 0, maxAspect > 0 else { return .zero }

        var contentW = w
        let contentH = h
        if contentW / contentH > maxAspect {
            contentW = contentH * maxAspect
        }
        // Only cap *maximum* aspect (width/height); portrait stays full-bleed.

        var x = (w - contentW) * 0.5
        var y = (h - contentH) * 0.5
        if snapPixels {
            x = x.rounded(.toNearestOrAwayFromZero)
            y = y.rounded(.toNearestOrAwayFromZero)
            contentW = contentW.rounded(.toNearestOrAwayFromZero)
            // Keep height full-bleed when it already fills; otherwise snap.
            let ch = contentH.rounded(.toNearestOrAwayFromZero)
            return CGRect(x: x, y: y, width: max(1, contentW), height: max(1, ch))
        }
        return CGRect(x: x, y: y, width: contentW, height: contentH)
    }
}
