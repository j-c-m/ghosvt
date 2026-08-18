import AppKit
import CGhosttyVT
import Foundation

/// Per-VT stolen-row search HUD.
struct VTSearchState {
    var isOpen = false
    var needle = ""
    var matches: [TerminalSession.SearchMatch] = []
    var index = 0
}

/// Per-VT address bar / nav chrome.
struct VTBrowserChrome {
    var address = ""
    var editing = false
    var caret = 0
    var selAnchor = 0
    var canGoBack = false
    var canGoForward = false
    var visibleStart = 0

    var hasSelection: Bool { selAnchor != caret }
    var selLo: Int { min(selAnchor, caret) }
    var selHi: Int { max(selAnchor, caret) }

    mutating func clearSelection() {
        selAnchor = caret
    }

    mutating func selectAll() {
        selAnchor = 0
        caret = address.count
    }
}

/// Multi-tab browser state for one VT.
final class BrowserSession {
    var tabs: [EmbeddedBrowserView] = []
    var activeTabIndex: Int = 0

    var activeBrowser: EmbeddedBrowserView? {
        guard activeTabIndex >= 0, activeTabIndex < tabs.count else { return nil }
        return tabs[activeTabIndex]
    }

    var showsTabStrip: Bool { tabs.count > 1 }
    var stolenChromeRows: Int { showsTabStrip ? 2 : 1 }
    var findOpen = false
    var findNeedle = ""
    var findHasMatch = true
}

/// One VT’s host overlays: search HUD, optional browser session, address chrome.
struct VTOverlay {
    var search = VTSearchState()
    var session: BrowserSession?
    var chrome = VTBrowserChrome()
}

/// Sized from `vtCount`. Replaces parallel search/session/chrome arrays.
final class OverlayStore {
    var slots: [VTOverlay] = []

    func ensure(count n: Int) {
        guard n > 0 else { return }
        if slots.count < n {
            slots.append(contentsOf: repeatElement(VTOverlay(), count: n - slots.count))
        }
    }

    var count: Int { slots.count }

    subscript(index: Int) -> VTOverlay {
        get { slots[index] }
        set { slots[index] = newValue }
    }

    func enumerated() -> EnumeratedSequence<[VTOverlay]> {
        slots.enumerated()
    }
}

/// Stolen-row layout: `/needle` left; count + ↑ ↓ right.
struct SearchHUDLayout {
    var line: String
    var caretCol: Int
    var upCol: Int
    var downCol: Int
}

struct BrowserHUDLayout {
    var line: String
    var caretCol: Int
    var backCol: Int
    var forwardCol: Int
    var closeCol: Int
    var urlStart: Int
    var urlEnd: Int
    var actionCols: [Int] = []
    var visibleStart: Int = 0
    var selStartCol: Int = -1
    var selEndCol: Int = -1
    var hasSelection: Bool { selStartCol >= 0 && selEndCol > selStartCol }
}

struct BrowserTabStripLayout {
    var line: String
    var activeStart: Int
    var activeEnd: Int
    var tabs: [(start: Int, end: Int, closeCol: Int)]
    var plusCol: Int
}

enum OverlayCells {
    static func columnCount(_ s: String) -> Int {
        var n = 0
        for scalar in s.unicodeScalars {
            n += Int(ghostty_unicode_codepoint_width(scalar.value))
        }
        return n
    }

    static func prefixFitting(_ s: String, maxCols: Int) -> String {
        guard maxCols > 0 else { return "" }
        var used = 0
        var out = ""
        for ch in s {
            let w = columnCount(String(ch))
            if w == 0 {
                out.append(ch)
                continue
            }
            if used + w > maxCols { break }
            out.append(ch)
            used += w
        }
        return out
    }

    static func place(_ s: String, at start: Int, into cells: inout [String]) {
        var col = start
        for ch in s {
            let w = columnCount(String(ch))
            if w == 0 {
                if col > start, col - 1 < cells.count {
                    cells[col - 1].append(ch)
                }
                continue
            }
            if col >= cells.count { break }
            cells[col] = String(ch)
            for k in 1..<w where col + k < cells.count {
                cells[col + k] = " "
            }
            col += w
        }
    }
}
