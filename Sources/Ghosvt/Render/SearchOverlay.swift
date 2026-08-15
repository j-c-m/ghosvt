import AppKit
import Foundation

/// Stolen-row scrollback search HUD. Per-VT state lives in `OverlayStore`.
@MainActor
final class SearchOverlay {
    unowned let host: MetalTerminalView
    private var debounce: DispatchWorkItem?

    init(host: MetalTerminalView) {
        self.host = host
    }

    var isOpen: Bool {
        get { state?.isOpen ?? false }
        set {
            host.ensureOverlays()
            guard let i = host.manager?.activeIndex, i < host.overlays.count else { return }
            host.overlays[i].search.isOpen = newValue
        }
    }

    var needle: String {
        get { state?.needle ?? "" }
        set {
            host.ensureOverlays()
            guard let i = host.manager?.activeIndex, i < host.overlays.count else { return }
            host.overlays[i].search.needle = newValue
        }
    }

    private var matches: [TerminalSession.SearchMatch] {
        get { state?.matches ?? [] }
        set {
            host.ensureOverlays()
            guard let i = host.manager?.activeIndex, i < host.overlays.count else { return }
            host.overlays[i].search.matches = newValue
        }
    }

    private var index: Int {
        get { state?.index ?? 0 }
        set {
            host.ensureOverlays()
            guard let i = host.manager?.activeIndex, i < host.overlays.count else { return }
            host.overlays[i].search.index = newValue
        }
    }

    private var state: VTSearchState? {
        guard let i = host.manager?.activeIndex, i < host.overlays.count else { return nil }
        return host.overlays[i].search
    }

    func hudLayout(cols: Int) -> SearchHUDLayout {
        guard cols > 0 else {
            return SearchHUDLayout(line: "/", caretCol: 1, upCol: -1, downCol: -1)
        }
        let status: String
        if needle.isEmpty {
            status = ""
        } else if matches.isEmpty {
            status = "-/0"
        } else {
            status = "\(index + 1)/\(matches.count)"
        }
        // Trailing chrome: optional status, then ↑ space ↓ (Ghostty up=next).
        let nav = "↑ ↓"
        let right = status.isEmpty ? (" " + nav) : (" " + status + " " + nav)
        let rightCols = OverlayCells.columnCount(right)

        // Prefer keeping right chrome; fit `/` + needle into the rest.
        let leftBudget = max(1, cols - rightCols)
        let slash = "/"
        let slashCols = OverlayCells.columnCount(slash)
        let needleBudget = max(0, leftBudget - slashCols)
        let shown = OverlayCells.prefixFitting(needle, maxCols: needleBudget)
        let left = slash + shown
        let leftCols = OverlayCells.columnCount(left)
        let caretCol = min(leftCols, cols - 1)

        // Cell slots (one glyph start or spacer per column) so wide chars don't
        // desync caret / ↑↓ hit targets.
        var cells = Array(repeating: " ", count: cols)
        OverlayCells.place(left, at: 0, into: &cells)
        let rightStart = max(0, cols - rightCols)
        OverlayCells.place(right, at: rightStart, into: &cells)
        let line = cells.joined()

        // Line ends with "↑ ↓" (three cells) → up at cols-3, down at cols-1.
        let upCol = cols >= 3 ? cols - 3 : -1
        let downCol = cols >= 1 ? cols - 1 : -1
        return SearchHUDLayout(line: line, caretCol: caretCol, upCol: upCol, downCol: downCol)
    }

    /// Click ↑ / ↓ on the stolen search row.
    @discardableResult
    func handleRowClick(_ event: NSEvent) -> Bool {
        guard isOpen else { return false }
        guard let cell = host.fullGridCell(at: event),
              let full = host.fullGridSize()
        else { return false }
        // Stolen row: top of full grid, or last row when bottom.
        let searchRow = host.config.searchPosition == .top ? 0 : Int(full.rows) - 1
        guard cell.row == searchRow else { return false }
        let layout = hudLayout(cols: Int(full.cols))
        if cell.col == layout.upCol {
            navigate(reverse: false)
            return true
        }
        if cell.col == layout.downCol {
            navigate(reverse: true)
            return true
        }
        // Click elsewhere on the search row: keep focus, do not start selection.
        return true
    }

    /// Map screen-coordinate matches into the current viewport for paint.
    func viewportHighlights(
        session: TerminalSession
    ) -> [TerminalRenderer.SearchHighlightRange] {
        guard isOpen, !matches.isEmpty else { return [] }
        guard let snap = session.queryScrollbar() else { return [] }
        let offset = Int(snap.offset)
        let vpRows = Int(snap.len)
        guard vpRows > 0 else { return [] }
        var out: [TerminalRenderer.SearchHighlightRange] = []
        out.reserveCapacity(min(matches.count, 64))
        for (i, m) in matches.enumerated() {
            let row = Int(m.screenY) - offset
            guard row >= 0, row < vpRows else { continue }
            out.append(TerminalRenderer.SearchHighlightRange(
                row: row,
                startX: Int(m.startX),
                endX: Int(m.endX),
                isCurrent: i == index
            ))
        }
        return out
    }

    /// Handle ⌘F / ⌘G / Esc-when-search-open. Returns true if consumed.
    @discardableResult
    func handleKeys(_ event: NSEvent) -> Bool {
        if KeyBridge.isSearchToggle(event) {
            if isOpen {
                close()
            } else {
                open()
            }
            return true
        }
        if let forward = KeyBridge.searchNavigateForward(from: event) {
            if isOpen {
                navigate(reverse: !forward)
                return true
            }
            return false
        }
        if isOpen, event.keyCode == 53 { // Escape
            close()
            return true
        }
        return false
    }

    /// Typing into the stolen search row (not the PTY).
    @discardableResult
    func handleTyping(_ event: NSEvent) -> Bool {
        guard isOpen else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.control) {
            return false
        }

        switch event.keyCode {
        case 36, 76: // Return / keypad Enter
            if matches.isEmpty, !needle.isEmpty {
                run(needle: needle, selectFirst: true)
            } else {
                navigate(reverse: flags.contains(.shift))
            }
            return true
        case 51: // Delete (backspace)
            if !needle.isEmpty {
                needle.removeLast()
                schedule()
            }
            return true
        case 117: // Forward delete — clear last grapheme cluster end; same as backspace for MVP
            if !needle.isEmpty {
                needle.removeLast()
                schedule()
            }
            return true
        case 126: // Up → next (older), Ghostty chevron.up
            navigate(reverse: false)
            return true
        case 125: // Down → previous (newer)
            navigate(reverse: true)
            return true
        default:
            break
        }

        if let chars = event.characters {
            var changed = false
            for ch in chars {
                let v = ch.unicodeScalars.first?.value ?? 0
                // Printable; drop C0 and macOS PUA function keys.
                if v >= 0x20, v != 0x7F, !(v >= 0xF700 && v <= 0xF8FF) {
                    needle.append(ch)
                    changed = true
                }
            }
            if changed {
                schedule()
                return true
            }
        }
        // Swallow other non-command keys so they never reach the shell.
        return true
    }

    func open() {
        host.ensureOverlays()
        if isOpen { return }
        isOpen = true
        host.applyResize()
        host.window?.makeFirstResponder(host)
        if !needle.isEmpty {
            run(needle: needle, selectFirst: true)
        } else {
            matches = []
            index = 0
        }
    }

    func close() {
        host.ensureOverlays()
        guard isOpen else { return }
        debounce?.cancel()
        debounce = nil
        isOpen = false
        matches = []
        index = 0
        // Keep needle on this VT so reopening restores the last query.
        host.manager?.active.clearSelection()
        host.applyResize()
        host.window?.makeFirstResponder(host)
    }

    func cancelDebounce() {
        debounce?.cancel()
        debounce = nil
    }

    func run(needle: String, selectFirst: Bool) {
        self.needle = needle
        guard let session = host.manager?.active else {
            matches = []
            index = 0
            host.requestFrame()
            return
        }
        if needle.isEmpty {
            matches = []
            index = 0
            session.clearSelection()
            host.requestFrame()
            return
        }
        let found = session.findMatches(needle: needle)
        matches = found
        if found.isEmpty {
            index = 0
            session.clearSelection()
            host.requestFrame()
            return
        }
        // Matches are newest-first (index 0 = bottom of scrollback). Start there.
        if selectFirst {
            index = 0
        } else {
            index = min(index, found.count - 1)
        }
        applyCurrentMatch()
        host.requestFrame()
    }

    private func schedule() {
        debounce?.cancel()
        let needle = self.needle
        let work = DispatchWorkItem { [weak self] in
            self?.run(needle: needle, selectFirst: true)
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    private func navigate(reverse: Bool) {
        guard !matches.isEmpty else {
            if !needle.isEmpty {
                run(needle: needle, selectFirst: true)
            }
            return
        }
        // Ghostty: next = older (up / higher index), prev = newer (down / lower index).
        if reverse {
            index = (index - 1 + matches.count) % matches.count
        } else {
            index = (index + 1) % matches.count
        }
        applyCurrentMatch()
    }

    private func applyCurrentMatch() {
        guard let session = host.manager?.active,
              matches.indices.contains(index)
        else { return }
        let match = matches[index]
        // Highlight all matches in paint (gold / peach). Do not install VT selection.
        session.clearSelection()
        session.scrollToSearchMatch(match)
    }
}
