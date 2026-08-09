import Foundation

/// Continuous scroll position + DOS-demo-style spring overscroll.
///
/// Units: **rows** (viewport-relative). `position == 0` is the top of scrollback;
/// `position == maxOffset` is pinned to the active bottom. Overshoot beyond
/// [0, maxOffset] is allowed and pulled back with a spring.
final class ScrollPhysics {
    /// Continuous offset into the scrollable range (rows from top of history).
    private(set) var position: Double = 0
    /// Rows per second.
    private(set) var velocity: Double = 0
    /// When true, stick to the bottom as new output arrives.
    private(set) var pinnedToBottom: Bool = true

    var springK: Double = 120
    var springC: Double = 14
    var friction: Double = 6
    /// Max overscroll as a fraction of the visible viewport height (rows).
    var maxOverscrollFraction: Double = 0.35
    /// Wheel/trackpad → velocity scale.
    var impulseScale: Double = 18

    private let settlePos: Double = 0.02
    private let settleVel: Double = 0.15

    /// Integer row for `GHOSTTY_SCROLL_VIEWPORT_ROW` (clamped into range).
    func integerRow(maxOffset: Double) -> UInt64 {
        let maxO = max(0, maxOffset)
        if position <= 0 { return 0 }
        if position >= maxO { return UInt64(maxO.rounded(.down)) }
        return UInt64(position.rounded(.down))
    }

    /// Fractional part in [0, 1) while in range; overscroll encoded as offset outside.
    /// Pixel shift applied as `y += visualOffsetRows * cellHeight` (top-left coords).
    func visualOffsetRows(maxOffset: Double) -> Double {
        let maxO = max(0, maxOffset)
        if position < 0 {
            // Pull content downward (reveal empty above).
            return -position
        }
        if position > maxO {
            // Pull content upward past the bottom.
            return -(position - maxO)
        }
        let frac = position - floor(position)
        // Shift content up so the next row peeks in from the bottom.
        return -frac
    }

    /// Apply a wheel/trackpad impulse.
    /// Positive `deltaRows` moves toward older history (position decreases toward 0).
    func applyImpulse(deltaRows: Double) {
        if abs(deltaRows) < 1e-9 { return }
        pinnedToBottom = false
        // +impulse → older history → lower position → negative velocity.
        velocity -= deltaRows * impulseScale
    }

    /// Jump to bottom and pin.
    func pinBottom(maxOffset: Double) {
        let maxO = max(0, maxOffset)
        position = maxO
        velocity = 0
        pinnedToBottom = true
    }

    /// Keep pinned bottom glued when scrollback grows.
    func followBottomIfPinned(maxOffset: Double) {
        guard pinnedToBottom else { return }
        let maxO = max(0, maxOffset)
        position = maxO
        velocity = 0
    }

    /// Integrate one frame. Returns true if still moving (needs redraw).
    @discardableResult
    func step(dt: Double, maxOffset: Double, viewportRows: Double) -> Bool {
        let maxO = max(0, maxOffset)
        let maxOver = max(0.5, viewportRows * maxOverscrollFraction)
        let dt = min(max(dt, 0), 0.05)

        if pinnedToBottom {
            position = maxO
            velocity = 0
            return false
        }

        // Integrate
        position += velocity * dt

        // Soft clamp overscroll
        if position < -maxOver {
            position = -maxOver
            velocity = max(0, velocity)
        } else if position > maxO + maxOver {
            position = maxO + maxOver
            velocity = min(0, velocity)
        }

        // Forces
        if position < 0 {
            // Spring toward 0
            let x = position
            let a = -springK * x - springC * velocity
            velocity += a * dt
        } else if position > maxO {
            let x = position - maxO
            let a = -springK * x - springC * velocity
            velocity += a * dt
        } else {
            // Friction / coast inside the range
            velocity *= exp(-friction * dt)
            if abs(velocity) < settleVel {
                velocity = 0
            }
        }

        // Settle overscroll
        if position < 0 || position > maxO {
            if abs(velocity) < settleVel, abs(position < 0 ? position : position - maxO) < settlePos {
                position = min(max(position, 0), maxO)
                velocity = 0
                if abs(position - maxO) < settlePos {
                    pinnedToBottom = true
                    position = maxO
                }
            }
        } else if abs(velocity) < settleVel {
            velocity = 0
            // Snap fractional settle toward nearest integer? Keep continuous until idle pin.
            if abs(position - maxO) < settlePos {
                pinnedToBottom = true
                position = maxO
            }
        }

        return abs(velocity) > settleVel
            || position < -settlePos
            || position > maxO + settlePos
    }

    /// Sync continuous position from terminal scrollbar after external changes.
    func syncFromScrollbar(offset: Double, maxOffset: Double, forcePinIfActive: Bool) {
        let maxO = max(0, maxOffset)
        if forcePinIfActive || pinnedToBottom {
            pinBottom(maxOffset: maxO)
            return
        }
        position = min(max(offset, 0), maxO)
        velocity = 0
    }
}
