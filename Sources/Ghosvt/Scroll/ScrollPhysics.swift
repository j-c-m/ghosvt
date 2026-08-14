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
    /// Absolute row offset to ease toward (search / programmatic scroll). Nil = free physics.
    private var seekTarget: Double?
    /// ⌘End / keystroke: `seekTarget` tracks the live bottom as output grows.
    private var seekFollowsBottom = false

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
        seekTarget = nil
        seekFollowsBottom = false
        pinnedToBottom = false
        // +impulse → older history → lower position → negative velocity.
        velocity -= deltaRows * impulseScale
    }

    /// Smooth page-key fling. `direction` +1 = older (Page Up), −1 = toward bottom.
    /// `holdCount` starts at 1 on first press and grows with key-repeat for acceleration.
    func applyPageImpulse(direction: Double, holdCount: Int, viewportRows: Double) {
        if abs(direction) < 1e-9 { return }
        seekTarget = nil
        seekFollowsBottom = false
        let vp = max(1, viewportRows)
        pinnedToBottom = false
        // Initial kick ~ coasts about a page; repeats multiply (capped).
        let base = vp * 5.5
        let mult = min(1.0 + Double(max(0, holdCount - 1)) * 0.45, 7.0)
        let kick = base * mult
        velocity -= direction * kick
        let cap = vp * 36
        velocity = min(max(velocity, -cap), cap)
    }

    /// Coast to the top (`direction` +1) or bottom (−1), then overscroll-bounce
    /// like page / wheel. Always reaches the extreme; repeats accelerate.
    func seekExtreme(
        direction: Double,
        holdCount: Int,
        viewportRows: Double,
        maxOffset: Double
    ) {
        if abs(direction) < 1e-9 { return }
        seekTarget = nil
        let maxO = max(0, maxOffset)
        let vp = max(1, viewportRows)
        let mult = min(1.0 + Double(max(0, holdCount - 1)) * 0.45, 7.0)
        pinnedToBottom = false
        seekFollowsBottom = direction < 0
        // Coast ≈ |v|/friction. Size to arrive, plus a page-edge leftover for bounce.
        let travel = direction > 0 ? max(0, position) : max(0, maxO - position)
        let speed = (travel * friction + vp * 1.5) * mult
        velocity = -direction * speed
        let cap = max(vp * 48, speed)
        velocity = min(max(velocity, -cap), cap)
    }

    /// Jump to top of scrollback.
    func pinTop(maxOffset: Double) {
        _ = maxOffset
        seekTarget = nil
        seekFollowsBottom = false
        position = 0
        velocity = 0
        pinnedToBottom = false
    }

    /// Jump to bottom and pin.
    func pinBottom(maxOffset: Double) {
        let maxO = max(0, maxOffset)
        seekTarget = nil
        seekFollowsBottom = false
        position = maxO
        velocity = 0
        pinnedToBottom = true
    }

    /// Ease to an absolute scroll offset (search match, etc.). Wheel / page keys cancel.
    func smoothTo(offset: Double, maxOffset: Double) {
        let maxO = max(0, maxOffset)
        let goal = min(max(offset, 0), maxO)
        pinnedToBottom = false
        seekFollowsBottom = false
        let err = goal - position
        if abs(err) < 0.35 {
            seekTarget = nil
            position = goal
            velocity = 0
            pinnedToBottom = abs(goal - maxO) < settlePos
            return
        }
        seekTarget = goal
        // Seed so the first frame moves; step() springs the rest of the way.
        velocity = err * 6
    }

    /// Already coasting toward the live bottom (do not start another kick).
    var isSeekingBottom: Bool { seekFollowsBottom }

    /// True when a keystroke should not start another bottom seek / bounce.
    func isAtLiveBottom(maxOffset: Double) -> Bool {
        let maxO = max(0, maxOffset)
        if position > maxO { return true }
        if pinnedToBottom, abs(position - maxO) < 0.35 { return true }
        return false
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
            seekTarget = nil
            seekFollowsBottom = false
            position = maxO
            velocity = 0
            return false
        }

        // Live bottom grows while we coast toward it (Ctrl+C during output).
        if seekFollowsBottom {
            if position >= maxO {
                seekFollowsBottom = false
            } else {
                let minV = (maxO - position) * friction + viewportRows * 1.5
                if velocity < minV { velocity = minV }
            }
        }

        // Programmatic ease (search match). Extremes use free physics + bounce.
        if let target = seekTarget {
            return stepSeek(dt: dt, target: target, maxOffset: maxO, viewportRows: viewportRows)
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
            applyOverscrollSpring(offset: position, dt: dt)
            if velocity > 0, position + velocity * dt >= 0 {
                position = 0
                velocity = 0
            }
        } else if position > maxO {
            applyOverscrollSpring(offset: position - maxO, dt: dt)
            if velocity < 0, position + velocity * dt <= maxO {
                position = maxO
                velocity = 0
                pinnedToBottom = true
            }
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
            if abs(position - maxO) < settlePos {
                pinnedToBottom = true
                position = maxO
            }
        }

        return abs(velocity) > settleVel
            || position < -settlePos
            || position > maxO + settlePos
    }

    /// Overdamped rubber band. `springC` is a floor so config can damp more, not less.
    private func applyOverscrollSpring(offset: Double, dt: Double) {
        let c = max(springC, 2.4 * sqrt(springK))
        velocity += (-springK * offset - c * velocity) * dt
    }

    /// Spring toward `seekTarget` (critically-ish damped).
    private func stepSeek(
        dt: Double,
        target: Double,
        maxOffset: Double,
        viewportRows: Double
    ) -> Bool {
        let maxO = max(0, maxOffset)
        let goal = min(max(target, 0), maxO)
        let err = goal - position

        // Settle when close and slow.
        if abs(err) < 0.2, abs(velocity) < 2 {
            position = goal
            velocity = 0
            seekTarget = nil
            if abs(position - maxO) < settlePos {
                pinnedToBottom = true
                position = maxO
            }
            return false
        }

        // Stiffer than overscroll spring so long jumps finish in ~0.25–0.4s.
        let k = 110.0
        let c = 20.0
        let a = k * err - c * velocity
        velocity += a * dt
        let cap = max(viewportRows * 8, abs(err) * 14)
        velocity = min(max(velocity, -cap), cap)
        position += velocity * dt
        position = min(max(position, -0.5), maxO + 0.5)

        return true
    }

    /// Sync continuous position from terminal scrollbar after external changes.
    func syncFromScrollbar(offset: Double, maxOffset: Double, forcePinIfActive: Bool) {
        let maxO = max(0, maxOffset)
        if forcePinIfActive || pinnedToBottom {
            pinBottom(maxOffset: maxO)
            return
        }
        // Don't fight an active seek with hard snaps from scrollbar growth.
        if seekTarget != nil { return }
        position = min(max(offset, 0), maxO)
        velocity = 0
    }
}
