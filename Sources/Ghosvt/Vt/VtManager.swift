import Foundation

/// Owns N virtual terminal sessions; routes to the active one.
final class VtManager {
    let config: Config
    private(set) var sessions: [TerminalSession]
    private(set) var activeIndex: Int = 0

    /// Brief switch indicator text (nil when idle).
    private(set) var indicatorText: String?
    private var indicatorDeadline: Date?

    init(config: Config) {
        self.config = config
        self.sessions = (0..<config.vtCount).map { TerminalSession(index: $0, scrollbackLines: config.scrollbackLines) }
        for s in sessions {
            s.applyScrollConfig(config)
        }
    }

    var active: TerminalSession {
        sessions[activeIndex]
    }

    func ensureActiveStarted(cols: UInt16, rows: UInt16, cellWidthPx: UInt32, cellHeightPx: UInt32) {
        active.ensureStarted(cols: cols, rows: rows, cellWidthPx: cellWidthPx, cellHeightPx: cellHeightPx)
    }

    func resizeAll(cols: UInt16, rows: UInt16, cellWidthPx: UInt32, cellHeightPx: UInt32) {
        for s in sessions where s.isLive {
            s.resize(cols: cols, rows: rows, cellWidthPx: cellWidthPx, cellHeightPx: cellHeightPx)
        }
        // Active may not be live yet; ensure next start uses new size via caller.
    }

    func pollAllIO() {
        for s in sessions where s.isLive {
            s.pollIO()
        }
    }

    @discardableResult
    func switchTo(_ index: Int) -> Bool {
        guard index >= 0, index < sessions.count, index != activeIndex else { return false }
        activeIndex = index
        indicatorText = "VT \(index + 1)"
        indicatorDeadline = Date().addingTimeInterval(0.4)
        return true
    }

    func switchByDelta(_ delta: Int) {
        let n = sessions.count
        guard n > 0 else { return }
        let next = (activeIndex + delta % n + n) % n
        switchTo(next)
    }

    /// Clear expired indicator; returns current text if still showing.
    func tickIndicator() -> String? {
        if let deadline = indicatorDeadline, Date() >= deadline {
            indicatorText = nil
            indicatorDeadline = nil
        }
        return indicatorText
    }
}
