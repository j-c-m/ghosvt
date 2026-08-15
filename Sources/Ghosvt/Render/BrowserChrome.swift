import AppKit
import Foundation
import WebKit

/// Embedded browser chrome: session, address bar, tab strip, find HUD, extensions.
@MainActor
final class BrowserChrome: NSObject {
    unowned let view: MetalTerminalView
    var addressDragging = false
    private var pageClickMonitor: Any?
    private var extensionActionButtons: [NSButton] = []
    private weak var extensionPopupAnchor: NSView?
    private var openExtensionPopover: NSPopover?
    private var cachedExtensionActionCount = 0

    init(view: MetalTerminalView) {
        self.view = view
        super.init()
    }

    var activeSession: BrowserSession? {
        view.ensureOverlays()
        guard let i = view.manager?.activeIndex, i < view.overlays.count else { return nil }
        return view.overlays[i].session
    }

    var active: EmbeddedBrowserView? {
        activeSession?.activeBrowser
    }

    var isActive: Bool { active != nil }

    var isFindOpen: Bool { activeSession?.findOpen == true }

    var isAddressEditing: Bool {
        view.ensureOverlays()
        guard let i = view.manager?.activeIndex, i < view.overlays.count else { return false }
        return view.overlays[i].chrome.editing
    }

    var activeChrome: VTBrowserChrome? {
        view.ensureOverlays()
        guard let i = view.manager?.activeIndex, i < view.overlays.count else { return nil }
        return view.overlays[i].chrome
    }

    func updateActiveChrome(_ body: (inout VTBrowserChrome) -> Void) {
        view.ensureOverlays()
        guard let i = view.manager?.activeIndex, i < view.overlays.count else { return }
        body(&view.overlays.slots[i].chrome)
    }

    func browserTabStripLayout(cols: Int) -> BrowserTabStripLayout? {
        guard let session = activeSession, session.showsTabStrip, cols > 0 else {
            return nil
        }
        let n = session.tabs.count
        // Reserve 1 col for `+` and 1 spacer before it when possible.
        let plusBudget = 2
        let usable = max(1, cols - plusBudget)
        let tabWidth = max(4, usable / n)
        var cells = Array(repeating: " ", count: cols)
        var tabRanges: [(start: Int, end: Int, closeCol: Int)] = []
        var activeStart = -1
        var activeEnd = -1
        var col = 0
        for i in 0..<n {
            guard col < usable else { break }
            let start = col
            let end = min(usable, start + tabWidth)
            let closeCol = end - 1
            let titleBudget = max(0, end - start - 1) // leave close ×
            var title = session.tabs[i].pageTitle
            if title.isEmpty { title = "Tab" }
            let chars = Array(title)
            let slice = chars.prefix(titleBudget)
            for (j, ch) in slice.enumerated() where start + j < closeCol {
                cells[start + j] = String(ch)
            }
            if closeCol >= start, closeCol < cols {
                cells[closeCol] = "×"
            }
            tabRanges.append((start, end, closeCol))
            if i == session.activeTabIndex {
                activeStart = start
                activeEnd = end
            }
            col = end
        }
        let plusCol = min(cols - 1, max(usable, cols - 1))
        if plusCol >= 0, plusCol < cols {
            cells[plusCol] = "+"
        }
        return BrowserTabStripLayout(
            line: cells.joined(),
            activeStart: activeStart,
            activeEnd: activeEnd,
            tabs: tabRanges,
            plusCol: plusCol
        )
    }

    /// Idle address paint: host only (full URL while editing).
    func prettyBrowserAddress(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        if trimmed == "about:blank" { return "New Tab" }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            return trimmed
        }
        switch scheme {
        case "https", "http":
            break
        case "about":
            return trimmed
        case "safari-web-extension", "webkit-extension":
            // e.g. …/dashboard.html → "dashboard"
            let last = url.pathComponents.last ?? "extension"
            if last.hasSuffix(".html") {
                return String(last.dropLast(5))
            }
            return last.isEmpty ? "extension" : last
        case "data":
            return "data:…"
        case "blob":
            return "blob:…"
        default:
            return trimmed
        }
        var host = url.host ?? ""
        if host.hasPrefix("www.") {
            host = String(host.dropFirst(4))
        }
        if host.isEmpty { return trimmed }
        if let port = url.port {
            let def = scheme == "https" ? 443 : 80
            if port != def { host = "\(host):\(port)" }
        }
        // Keep `http://` so insecure origins stay obvious; elide `https://`.
        return scheme == "http" ? "http://\(host)" : host
    }

    /// Count of extension action slots for the active browser VT (0 if none / old macOS).
    /// Uses cache only — safe from `draw` / HUD layout.
    func extensionActionSlotCount() -> Int {
        guard active != nil else { return 0 }
        return cachedExtensionActionCount
    }

    /// `← →  [ext…]  <url…>                    ×` — stolen top terminal row.
    func browserHUDLayout(cols: Int) -> BrowserHUDLayout {
        let chrome = activeChrome ?? VTBrowserChrome()
        guard cols > 0 else {
            return BrowserHUDLayout(
                line: "×", caretCol: 0, backCol: -1, forwardCol: -1,
                closeCol: 0, urlStart: 0, urlEnd: 0
            )
        }
        let backCol = 0
        let forwardCol = 2
        let closeCol = cols - 1
        // After ← →, then one cell per extension action, then URL.
        // Layout: 0=←  2=→  4..=actions  then URL … close.
        // Keep a URL band so action icons cannot eat the type-in cells.
        let minUrlCols = 16
        let maxActions = max(0, closeCol - 4 - 1 - minUrlCols)
        let actionCount = min(extensionActionSlotCount(), maxActions)
        var actionCols: [Int] = []
        if actionCount > 0 {
            for i in 0..<actionCount {
                actionCols.append(4 + i)
            }
        }
        let urlStart = actionCount > 0 ? (4 + actionCount + 1) : 4
        let urlEnd = max(urlStart, closeCol)
        var cells = Array(repeating: " ", count: cols)
        if cols > 0 { cells[backCol] = chrome.canGoBack ? "←" : "·" }
        if cols > 2 { cells[forwardCol] = chrome.canGoForward ? "→" : "·" }
        // Action slots left blank (NSButton overlay paints the real icon).
        if cols > 0 { cells[closeCol] = "×" }
        let urlBudget = max(0, urlEnd - urlStart)
        // Idle: pretty shortened URL (display only). Editing: full raw address for typing.
        let addr: String
        if chrome.editing {
            addr = chrome.address.isEmpty ? "https://" : chrome.address
        } else {
            let pretty = prettyBrowserAddress(chrome.address)
            addr = pretty.isEmpty ? "New Tab" : pretty
        }
        let chars = Array(addr)
        let maxStart = max(0, chars.count - urlBudget)
        // Editing: keep caret (and selection edge) in the visible window.
        // Idle pretty form is host-first — always scroll from the start.
        let visibleStart: Int
        if urlBudget <= 0 || chars.count <= urlBudget {
            visibleStart = 0
        } else if chrome.editing {
            var vs = min(max(0, chrome.visibleStart), maxStart)
            let focus = chrome.caret
            if focus < vs { vs = focus }
            if focus > vs + urlBudget { vs = focus - urlBudget }
            // Prefer keeping the selection start visible when possible.
            if chrome.hasSelection {
                let lo = chrome.selLo
                if lo < vs { vs = lo }
                if chrome.selHi > vs + urlBudget {
                    vs = min(maxStart, chrome.selHi - urlBudget)
                }
            }
            visibleStart = min(max(0, vs), maxStart)
        } else {
            visibleStart = 0
        }
        let slice = chars.dropFirst(visibleStart).prefix(urlBudget)
        let urlCells = slice.map { String($0) }
        // Persist visible window for caret/click mapping (editing only matters).
        if chrome.editing {
            updateActiveChrome { $0.visibleStart = visibleStart }
        }
        // Idle: center host in the URL band. Editing: left-align for caret mapping.
        let paintOrigin = chrome.editing
            ? urlStart
            : urlStart + max(0, (urlBudget - urlCells.count) / 2)
        for (i, ch) in urlCells.enumerated() where paintOrigin + i < urlEnd {
            cells[paintOrigin + i] = ch
        }
        let caret: Int
        var selStartCol = -1
        var selEndCol = -1
        if chrome.editing {
            let visCaret = chrome.caret - visibleStart
            caret = min(urlStart + max(0, min(visCaret, max(0, urlBudget))), max(urlStart, urlEnd))
            // Clamp caret paint into the URL band (caret may sit past last char cell).
            let caretPaint = min(max(urlStart, caret), max(urlStart, urlEnd - 1))
            if chrome.hasSelection, urlBudget > 0 {
                let lo = max(0, chrome.selLo - visibleStart)
                let hi = max(0, chrome.selHi - visibleStart)
                let a = min(lo, hi)
                let b = max(lo, hi)
                if b > 0, a < urlBudget {
                    selStartCol = urlStart + max(0, a)
                    selEndCol = urlStart + min(urlBudget, b)
                }
            }
            return BrowserHUDLayout(
                line: cells.joined(),
                caretCol: caretPaint,
                backCol: backCol,
                forwardCol: forwardCol,
                closeCol: closeCol,
                urlStart: urlStart,
                urlEnd: urlEnd,
                actionCols: actionCols,
                visibleStart: visibleStart,
                selStartCol: selStartCol,
                selEndCol: selEndCol
            )
        } else {
            caret = -1
        }
        return BrowserHUDLayout(
            line: cells.joined(),
            caretCol: caret,
            backCol: backCol,
            forwardCol: forwardCol,
            closeCol: closeCol,
            urlStart: urlStart,
            urlEnd: urlEnd,
            actionCols: actionCols,
            visibleStart: visibleStart
        )
    }

    /// Discover/load Safari web extensions on first browser open (not at app launch).
    func ensureBrowserExtensionsLoaded() {
        guard #available(macOS 15.4, *) else { return }
        BrowserExtensionHost.shared.loadBundledExtensionsIfNeeded()
    }

    func openBrowser(url: URL, onVT index: Int) {
        ensureBrowserExtensionsLoaded()
        view.ensureOverlays()
        guard index >= 0, index < view.overlays.count else { return }
        view.clearLinkHover()
        if let full = view.fullGridSize() {
            view.lastCols = full.cols
            view.lastRows = full.rows
            view.lastCellW = full.cellW
            view.lastCellH = full.cellH
        }
        installBrowserPageClickMonitor()
        if let session = view.overlays[index].session, let active = session.activeBrowser {
            active.isHidden = false
            active.load(url: url)
            syncChromeFromBrowser(active, onVT: index)
            active.focusWebContent()
            showBrowserForActiveVT()
            view.layoutActiveBrowser()
            if #available(macOS 15.4, *) {
                BrowserExtensionHost.shared.tabPropertiesChanged(
                    browser: active,
                    vtIndex: index,
                    [.URL, .loading]
                )
            }
            return
        }
        openNewBrowserTab(url: url, onVT: index, activate: true, editAddress: false)
    }

    /// Create a new tab on `vt` (opens a session if needed). Caps at `BrowserSession.maxTabs`.
    @discardableResult
    func openNewBrowserTab(
        url: URL?,
        onVT index: Int,
        activate: Bool,
        editAddress: Bool
    ) -> EmbeddedBrowserView? {
        ensureBrowserExtensionsLoaded()
        view.ensureOverlays()
        guard index >= 0, index < view.overlays.count else { return nil }
        view.clearLinkHover()
        if let full = view.fullGridSize() {
            view.lastCols = full.cols
            view.lastRows = full.rows
            view.lastCellW = full.cellW
            view.lastCellH = full.cellH
        }
        installBrowserPageClickMonitor()

        let session: BrowserSession
        if let existing = view.overlays[index].session {
            session = existing
        } else {
            session = BrowserSession()
            view.overlays.slots[index].session = session
        }
        if session.tabs.count >= BrowserSession.maxTabs {
            fputs("ghosvt: browser tab cap (\(BrowserSession.maxTabs)) on vt=\(index)\n", stderr)
            if let url, let active = session.activeBrowser {
                active.load(url: url)
                if activate { activateBrowserTab(onVT: index, tabIndex: session.activeTabIndex) }
            }
            return session.activeBrowser
        }

        let browser = makeBrowserTabView(onVT: index)
        browser.pageZoom = view.pageZoomScale
        view.addSubview(browser)
        session.tabs.append(browser)
        let tabIndex = session.tabs.count - 1
        if #available(macOS 15.4, *) {
            _ = BrowserExtensionHost.shared.addTab(browser: browser, vtIndex: index, activate: activate)
        }
        if activate {
            session.activeTabIndex = tabIndex
        }
        let loadURL = url ?? URL(string: "about:blank")!
        browser.load(url: loadURL)
        showBrowserForActiveVT()
        view.layoutActiveBrowser()
        if activate {
            syncChromeFromBrowser(browser, onVT: index)
            if editAddress {
                beginBrowserAddressEdit(selectAll: true)
            } else {
                browser.focusWebContent()
            }
        }
        refreshExtensionToolbarCacheAndButtons()
        return browser
    }

    func makeBrowserTabView(onVT index: Int) -> EmbeddedBrowserView {
        let browser = EmbeddedBrowserView(frame: .zero)
        browser.onClose = { [weak self] in
            self?.dismissBrowser(onVT: index)
        }
        browser.onWebContentInteraction = { [weak self] in
            self?.endBrowserAddressEdit(focusWeb: false)
        }
        browser.onURLChange = { [weak self, weak browser] s, back, forward in
            guard let self, let browser else { return }
            DispatchQueue.main.async {
                self.view.ensureOverlays()
                guard index < self.view.overlays.count,
                      let session = self.view.overlays[index].session,
                      session.activeBrowser === browser,
                      index < self.view.overlays.count
                else { return }
                if !self.view.overlays[index].chrome.editing {
                    self.view.overlays[index].chrome.address = s
                    self.view.overlays[index].chrome.caret = s.count
                    self.view.overlays[index].chrome.selAnchor = s.count
                    self.view.overlays[index].chrome.visibleStart = 0
                }
                self.view.overlays[index].chrome.canGoBack = back
                self.view.overlays[index].chrome.canGoForward = forward
            }
        }
        browser.onNavigationStateChange = { [weak browser] in
            guard let browser else { return }
            if #available(macOS 15.4, *) {
                BrowserExtensionHost.shared.tabPropertiesChanged(
                    browser: browser,
                    vtIndex: index,
                    [.URL, .title, .loading, .size]
                )
            }
        }
        browser.onOpenInNewTab = { [weak self] url in
            self?.openNewBrowserTab(url: url, onVT: index, activate: true, editAddress: false)
        }
        return browser
    }

    func syncChromeFromBrowser(_ browser: EmbeddedBrowserView, onVT index: Int) {
        view.ensureOverlays()
        guard index < view.overlays.count else { return }
        let s = browser.currentURLString
        view.overlays[index].chrome.address = s
        view.overlays[index].chrome.caret = s.count
        view.overlays[index].chrome.selAnchor = s.count
        view.overlays[index].chrome.visibleStart = 0
        view.overlays[index].chrome.canGoBack = browser.canGoBack
        view.overlays[index].chrome.canGoForward = browser.canGoForward
        view.overlays[index].chrome.editing = false
    }

    func activateBrowserTab(onVT index: Int, tabIndex: Int) {
        view.ensureOverlays()
        guard index >= 0, index < view.overlays.count,
              let session = view.overlays[index].session,
              tabIndex >= 0, tabIndex < session.tabs.count
        else { return }
        if session.activeTabIndex != tabIndex {
            session.activeTabIndex = tabIndex
            if #available(macOS 15.4, *) {
                BrowserExtensionHost.shared.setActiveTab(vtIndex: index, tabIndex: tabIndex)
            }
        }
        if let b = session.activeBrowser {
            syncChromeFromBrowser(b, onVT: index)
        }
        showBrowserForActiveVT()
        view.layoutActiveBrowser()
        session.activeBrowser?.focusWebContent()
    }

    func closeBrowserTab(onVT index: Int, tabIndex: Int) {
        view.ensureOverlays()
        guard index >= 0, index < view.overlays.count,
              let session = view.overlays[index].session,
              tabIndex >= 0, tabIndex < session.tabs.count
        else { return }
        if session.tabs.count == 1 {
            dismissBrowser(onVT: index)
            return
        }
        let wasActive = session.activeTabIndex == tabIndex
        let browser = session.tabs[tabIndex]
        // Host first while the embed is still strongly held (didCloseTab / webView).
        if #available(macOS 15.4, *) {
            BrowserExtensionHost.shared.closeTab(vtIndex: index, tabIndex: tabIndex)
        }
        browser.removeFromSuperview()
        session.tabs.remove(at: tabIndex)
        // Mirror host active-index clamp; host already fired didActivateTab if needed.
        if session.activeTabIndex >= session.tabs.count {
            session.activeTabIndex = session.tabs.count - 1
        } else if tabIndex < session.activeTabIndex {
            session.activeTabIndex -= 1
        } else if wasActive {
            session.activeTabIndex = min(tabIndex, session.tabs.count - 1)
        }
        if let b = session.activeBrowser {
            syncChromeFromBrowser(b, onVT: index)
        }
        showBrowserForActiveVT()
        view.layoutActiveBrowser()
        session.activeBrowser?.focusWebContent()
    }

    /// ⌘X/C/V/A for the page when the address bar is not editing.
    @discardableResult
    func handleBrowserPageEditKeys(_ event: NSEvent) -> Bool {
        guard !isAddressEditing, let browser = active else { return false }
        return browser.performStandardEditKey(event)
    }

    /// Page Up / Page Down (bare or ⌘) scroll the WebView, not terminal history.
    @discardableResult
    func handleBrowserPageScrollKeys(_ event: NSEvent) -> Bool {
        guard !isAddressEditing, let browser = active else { return false }
        return browser.performPageScrollKey(event)
    }

    /// End address edit only on real left-clicks inside the WebView (not mouse-over).
    func installBrowserPageClickMonitor() {
        guard pageClickMonitor == nil else { return }
        pageClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
            [weak self] event in
            guard let self, self.isAddressEditing, let browser = self.active else {
                return event
            }
            // Convert click to metal-view coords; if inside browser frame → leave address edit.
            let p = self.view.convert(event.locationInWindow, from: nil)
            if browser.frame.contains(p) {
                // Not on the stolen address row (row 0 is above the webview).
                self.endBrowserAddressEdit(focusWeb: false)
                browser.notePageClick()
            }
            return event
        }
    }

    func removeBrowserPageClickMonitor() {
        if let m = pageClickMonitor {
            NSEvent.removeMonitor(m)
            pageClickMonitor = nil
        }
    }

    func dismissBrowser(onVT index: Int) {
        view.ensureOverlays()
        guard index >= 0, index < view.overlays.count else { return }
        openExtensionPopover?.close()
        openExtensionPopover = nil
        if #available(macOS 15.4, *) {
            BrowserExtensionHost.shared.unregister(vtIndex: index)
        }
        if let session = view.overlays[index].session {
            for t in session.tabs {
                t.removeFromSuperview()
            }
        }
        view.overlays.slots[index].session = nil
        if index < view.overlays.count {
            view.overlays.slots[index].chrome = VTBrowserChrome()
        }
        addressDragging = false
        cachedExtensionActionCount = 0
        hideExtensionActionButtons()
        if view.overlays.slots.allSatisfy({ $0.session == nil }) {
            removeBrowserPageClickMonitor()
        }
        view.clearLinkHover()
        if view.manager?.activeIndex == index {
            view.window?.makeFirstResponder(view)
        }
        // Terminal path must paint this turn (not wait for next key/mouse).
        // Async avoids re-entering draw from inside a key handler mid-frame.
        view.requestFrame()
    }

    func showBrowserForActiveVT() {
        view.ensureOverlays()
        let active = view.manager?.activeIndex ?? 0
        for (i, slot) in view.overlays.enumerated() {
            guard let session = slot.session else { continue }
            let vtVisible = (i == active)
            for (ti, tab) in session.tabs.enumerated() {
                let visible = vtVisible && ti == session.activeTabIndex
                tab.isHidden = !visible
                // WKWebView can keep compositing a hidden layer at its last frame.
                if !visible { tab.frame = .zero }
            }
        }
        if active < view.overlays.count {
            if let b = view.overlays[active].session?.activeBrowser {
                if view.overlays[active].chrome.address.isEmpty {
                    view.overlays[active].chrome.address = b.currentURLString
                }
                view.overlays[active].chrome.canGoBack = b.canGoBack
                view.overlays[active].chrome.canGoForward = b.canGoForward
            } else {
                hideExtensionActionButtons()
            }
        } else {
            hideExtensionActionButtons()
        }
        view.layoutActiveBrowser()
        view.requestFrame()
    }

    func endBrowserAddressEdit(focusWeb: Bool) {
        updateActiveChrome { $0.editing = false }
        addressDragging = false
        // Only move first responder when requested. Opening an extension popup must
        // leave address-edit without focusing the page (popup gets focus itself).
        if focusWeb {
            active?.focusWebContent()
        }
    }

    func beginBrowserAddressEdit(selectAll: Bool = false) {
        guard active != nil else { return }
        if let session = activeSession, session.findOpen {
            session.findOpen = false
            view.layoutActiveBrowser()
        }
        updateActiveChrome { chrome in
            let wasEditing = chrome.editing
            chrome.editing = true
            if chrome.address.isEmpty { chrome.address = "https://" }
            if selectAll {
                chrome.selectAll()
                chrome.visibleStart = 0
            } else if !wasEditing {
                // First focus (e.g. click): caret at end; caller may reposition.
                // Keep visibleStart so click maps to the painted window.
                chrome.caret = chrome.address.count
                chrome.selAnchor = chrome.caret
            }
            // Already editing + not selectAll: leave caret/selection alone.
        }
        addressDragging = false
        view.window?.makeFirstResponder(view)
        installBrowserPageClickMonitor()
    }

    /// Absolute address index under a full-grid column in the URL segment.
    func addressIndex(atUrlCol col: Int, bar: BrowserHUDLayout, chrome: VTBrowserChrome) -> Int {
        let vis = max(0, col - bar.urlStart)
        // Use the layout's painted window, not chrome.visibleStart (may change mid-click).
        return min(chrome.address.count, max(0, bar.visibleStart + vis))
    }

    func applyPageZoom(_ zoom: CGFloat) {
        for (i, slot) in view.overlays.enumerated() {
            guard let session = slot.session else { continue }
            for tab in session.tabs {
                tab.pageZoom = zoom
                if #available(macOS 15.4, *) {
                    BrowserExtensionHost.shared.tabPropertiesChanged(
                        browser: tab,
                        vtIndex: i,
                        [.zoomFactor]
                    )
                }
            }
        }
    }

    func hideAllBrowserViews() {
        for slot in view.overlays.slots {
            guard let session = slot.session else { continue }
            for tab in session.tabs {
                tab.isHidden = true
                tab.frame = .zero
            }
        }
        hideExtensionActionButtons()
    }

    func hideExtensionActionButtons() {
        for b in extensionActionButtons {
            b.isHidden = true
        }
    }

    /// Query host + rebuild button images (not from `draw`).
    func refreshExtensionToolbarCacheAndButtons() {
        guard #available(macOS 15.4, *), active != nil,
              let vt = view.manager?.activeIndex
        else {
            cachedExtensionActionCount = 0
            hideExtensionActionButtons()
            return
        }
        let items = BrowserExtensionHost.shared.toolbarItems(forVT: vt)
        cachedExtensionActionCount = items.count
        ensureExtensionActionButtonCount(items.count)
        let bar = browserHUDLayout(cols: max(1, Int(view.lastCols)))
        let cols = bar.actionCols
        for (i, btn) in extensionActionButtons.enumerated() {
            guard i < items.count, i < cols.count,
                  let frame = view.fullGridCellFrame(col: cols[i], row: 0)
            else {
                btn.isHidden = true
                continue
            }
            let item = items[i]
            let action = item.action
            let size = CGSize(width: max(16, frame.width), height: max(16, frame.height))
            btn.image = action.icon(for: size)
            btn.isEnabled = action.isEnabled
            btn.isHidden = false
            btn.tag = i
            let badge = action.badgeText
            var tip = action.label
            if !badge.isEmpty {
                tip = tip.isEmpty ? badge : "\(tip) (\(badge))"
            }
            btn.toolTip = tip.isEmpty ? item.context.webExtension.displayName : tip
            let inset = max(1, min(frame.width, frame.height) * 0.1)
            btn.frame = frame.insetBy(dx: inset, dy: inset)
        }
        for i in items.count..<extensionActionButtons.count {
            extensionActionButtons[i].isHidden = true
        }
        view.requestFrame()
    }

    /// Reposition existing buttons only (paint path / layout).
    func layoutExtensionActionButtons(layout: BrowserHUDLayout) {
        guard active != nil else {
            hideExtensionActionButtons()
            return
        }
        let cols = layout.actionCols
        for (i, btn) in extensionActionButtons.enumerated() {
            guard i < cachedExtensionActionCount, i < cols.count,
                  let frame = view.fullGridCellFrame(col: cols[i], row: 0)
            else {
                btn.isHidden = true
                continue
            }
            let inset = max(1, min(frame.width, frame.height) * 0.1)
            btn.frame = frame.insetBy(dx: inset, dy: inset)
            btn.isHidden = false
        }
    }

    func ensureExtensionActionButtonCount(_ n: Int) {
        while extensionActionButtons.count < n {
            let btn = NSButton(frame: .zero)
            btn.isBordered = false
            btn.imagePosition = .imageOnly
            btn.imageScaling = .scaleProportionallyDown
            btn.setButtonType(.momentaryChange)
            btn.focusRingType = .none
            btn.wantsLayer = true
            btn.layer?.backgroundColor = NSColor.clear.cgColor
            btn.layer?.masksToBounds = true
            btn.target = self
            btn.action = #selector(extensionActionButtonClicked(_:))
            view.addSubview(btn)
            extensionActionButtons.append(btn)
        }
    }

    @objc func extensionActionButtonClicked(_ sender: NSButton) {
        performExtensionAction(at: sender.tag, anchorCol: nil, anchorView: sender)
    }

    func performExtensionAction(
        at index: Int,
        anchorCol: Int?,
        anchorView: NSView? = nil
    ) {
        guard #available(macOS 15.4, *), let vt = view.manager?.activeIndex else { return }
        let items = BrowserExtensionHost.shared.toolbarItems(forVT: vt)
        guard index >= 0, index < items.count else { return }
        // Drop address-bar first-responder so the popup can take typing.
        endBrowserAddressEdit(focusWeb: false)
        if let anchorView {
            extensionPopupAnchor = anchorView
        } else if let col = anchorCol,
                  let frame = view.fullGridCellFrame(col: col, row: 0) {
            ensureExtensionActionButtonCount(index + 1)
            extensionActionButtons[index].frame = frame
            extensionPopupAnchor = extensionActionButtons[index]
        }
        BrowserExtensionHost.shared.performToolbarItem(items[index], forVT: vt)
    }

    @available(macOS 15.4, *)
    func presentExtensionActionPopup(
        _ action: WKWebExtension.Action,
        completion: @escaping ((any Error)?) -> Void
    ) {
        guard action.presentsPopup else {
            completion(BrowserExtensionHost.unsupportedError("action has no popup"))
            return
        }
        // Access popupWebView so WebKit starts loading the action page.
        guard let webView = action.popupWebView else {
            completion(BrowserExtensionHost.unsupportedError("action has no popup webView"))
            return
        }
        webView.isInspectable = true
        #if DEBUG
        fputs(
            "ghosvt: webext present popup label=\(action.label) "
                + "url=\(webView.url?.absoluteString ?? "nil")\n",
            stderr
        )
        #endif
        guard let popover = action.popupPopover else {
            completion(BrowserExtensionHost.unsupportedError("action has no popup popover"))
            return
        }
        let anchor = extensionPopupAnchor
            ?? extensionActionButtons.first(where: { !$0.isHidden })
            ?? view
        // Leave address-edit without focusing the page webview.
        endBrowserAddressEdit(focusWeb: false)
        openExtensionPopover?.close()
        openExtensionPopover = popover
        popover.behavior = .transient
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        action.hasUnreadBadgeText = false
        // After show, move key focus into the popup (password field, etc.).
        DispatchQueue.main.async { [weak webView, weak self] in
            guard let webView else { return }
            let win = webView.window ?? self?.view.window
            win?.makeFirstResponder(webView)
        }
        completion(nil)
    }

    /// Drag-extend selection while mouse is down in the address bar.
    func handleBrowserAddressDrag(_ event: NSEvent) {
        guard addressDragging, isAddressEditing else { return }
        guard let cell = view.fullGridCell(at: event) else { return }
        let bar = browserHUDLayout(cols: Int(view.lastCols))
        // Allow drag past the URL band: clamp to ends.
        let col: Int
        if cell.row != 0 {
            // Drag on strip / content: keep last caret (only page click ends edit).
            return
        }
        if cell.col < bar.urlStart {
            col = bar.urlStart
        } else if cell.col >= bar.urlEnd {
            col = max(bar.urlStart, bar.urlEnd - 1)
        } else {
            col = cell.col
        }
        updateActiveChrome { c in
            c.caret = self.addressIndex(atUrlCol: col, bar: bar, chrome: c)
            // Drag past last visible cell → end of address.
            if cell.col >= bar.urlEnd {
                c.caret = c.address.count
            }
        }
    }

    @discardableResult
    func handleBrowserHUDClick(_ event: NSEvent) -> Bool {
        guard active != nil, let vt = view.manager?.activeIndex else { return false }
        guard let cell = view.fullGridCell(at: event) else { return false }
        let strip = browserTabStripLayout(cols: Int(view.lastCols))
        // Row 1: tab strip (only when multi-tab).
        if let strip, cell.row == 1 {
            endBrowserAddressEdit(focusWeb: false)
            if cell.col == strip.plusCol {
                openNewBrowserTab(
                    url: URL(string: "about:blank"),
                    onVT: vt,
                    activate: true,
                    editAddress: true
                )
                return true
            }
            for (i, t) in strip.tabs.enumerated() {
                if cell.col == t.closeCol {
                    closeBrowserTab(onVT: vt, tabIndex: i)
                    return true
                }
                if cell.col >= t.start, cell.col < t.end {
                    activateBrowserTab(onVT: vt, tabIndex: i)
                    return true
                }
            }
            return true
        }
        if isFindOpen, let full = view.fullGridSize(), cell.row == Int(full.rows) - 1 {
            let find = browserFindHUDLayout(cols: Int(view.lastCols))
            if cell.col == find.upCol {
                runBrowserFind(backwards: false)
                return true
            }
            if cell.col == find.downCol {
                runBrowserFind(backwards: true)
                return true
            }
            view.window?.makeFirstResponder(view)
            return true
        }
        // Address bar is full-grid row 0 when browser is open.
        guard cell.row == 0 else {
            return false
        }
        let bar = browserHUDLayout(cols: Int(view.lastCols))
        if cell.col == bar.backCol {
            endBrowserAddressEdit(focusWeb: false)
            active?.goBack()
            return true
        }
        if cell.col == bar.forwardCol {
            endBrowserAddressEdit(focusWeb: false)
            active?.goForward()
            return true
        }
        if bar.actionCols.contains(cell.col) {
            endBrowserAddressEdit(focusWeb: false)
            if let idx = bar.actionCols.firstIndex(of: cell.col) {
                performExtensionAction(at: idx, anchorCol: cell.col)
            }
            return true
        }
        if cell.col == bar.closeCol {
            dismissBrowser(onVT: vt)
            return true
        }
        if cell.col >= bar.urlStart, cell.col < bar.urlEnd {
            // Idle paints a centered host-only string — column→caret mapping is wrong
            // until the full URL is left-aligned for edit. Enter with select-all.
            if !isAddressEditing {
                beginBrowserAddressEdit(selectAll: true)
                return true
            }
            let shift = event.modifierFlags.contains(.shift)
            beginBrowserAddressEdit()
            updateActiveChrome { c in
                let idx = self.addressIndex(atUrlCol: cell.col, bar: bar, chrome: c)
                if shift {
                    c.caret = idx
                } else {
                    c.caret = idx
                    c.selAnchor = idx
                }
            }
            addressDragging = true
            return true
        }
        // Click on chrome padding between buttons: keep/start edit without moving caret.
        if !isAddressEditing {
            beginBrowserAddressEdit(selectAll: true)
        }
        return true
    }

    /// Carbon HIToolbox virtual key codes (ANSI US) for reliable ⌘ chords.
    enum BrowserKeyCode {
        static let a: UInt16 = 0x00
        static let b: UInt16 = 0x0B
        static let c: UInt16 = 0x08
        static let t: UInt16 = 0x11
        static let v: UInt16 = 0x09
        static let w: UInt16 = 0x0D
        static let r: UInt16 = 0x0F
        static let l: UInt16 = 0x25
        static let f: UInt16 = 0x03
        static let q: UInt16 = 0x0C
        static let leftBracket: UInt16 = 0x21
        static let rightBracket: UInt16 = 0x1E
        static let leftArrow: UInt16 = 0x7B
        static let rightArrow: UInt16 = 0x7C
    }

    func isCommandChord(
        _ event: NSEvent,
        keyCode: UInt16,
        char: String,
        allowShift: Bool = false
    ) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command),
              !flags.contains(.control),
              !flags.contains(.option)
        else { return false }
        if !allowShift, flags.contains(.shift) { return false }
        if event.keyCode == keyCode { return true }
        return event.charactersIgnoringModifiers?.lowercased() == char
    }

    /// ⌘B: open (or focus) the embedded browser on the active VT.
    @discardableResult
    func handleOpenBrowserChord(_ event: NSEvent) -> Bool {
        guard view.config.embeddedBrowser else { return false }
        guard isCommandChord(event, keyCode: BrowserKeyCode.b, char: "b") else { return false }
        guard let manager = view.manager else { return false }
        let index = manager.activeIndex
        view.ensureOverlays()
        if index < view.overlays.count, view.overlays[index].session?.activeBrowser != nil {
            beginBrowserAddressEdit(selectAll: true)
            return true
        }
        openNewBrowserTab(
            url: URL(string: "about:blank"),
            onVT: index,
            activate: true,
            editAddress: true
        )
        return true
    }

    /// ⌘W / ⌘T / address typing while a browser is active on this VT.
    @discardableResult
    func handleBrowserKeys(_ event: NSEvent) -> Bool {
        let handled = handleBrowserKeyEvent(event)
        return handled
    }

    func handleBrowserKeyEvent(_ event: NSEvent) -> Bool {
        // ⌘B works even before a browser exists on this VT.
        if handleOpenBrowserChord(event) { return true }
        // ⌘T: new tab (opens browser if needed).
        if isCommandChord(event, keyCode: BrowserKeyCode.t, char: "t") {
            guard let i = view.manager?.activeIndex else { return false }
            openNewBrowserTab(
                url: URL(string: "about:blank"),
                onVT: i,
                activate: true,
                editAddress: true
            )
            return true
        }
        guard active != nil, let i = view.manager?.activeIndex else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let editing = isAddressEditing

        if isCommandChord(event, keyCode: BrowserKeyCode.l, char: "l") {
            beginBrowserAddressEdit(selectAll: true)
            return true
        }
        if event.keyCode == 53 { // Escape
            if isFindOpen {
                closeBrowserFind()
                return true
            }
            if editing {
                endBrowserAddressEdit(focusWeb: true)
                return true
            }
            return false
        }
        if isCommandChord(event, keyCode: BrowserKeyCode.q, char: "q")
            || isCommandChord(event, keyCode: BrowserKeyCode.w, char: "w") {
            dismissBrowser(onVT: i)
            return true
        }
        if isCommandChord(event, keyCode: BrowserKeyCode.f, char: "f") {
            toggleBrowserFind()
            return true
        }
        if let forward = KeyBridge.searchNavigateForward(from: event) {
            if isFindOpen {
                runBrowserFind(backwards: !forward)
                return true
            }
            return false
        }
        if isFindOpen, handleBrowserFindTyping(event) {
            return true
        }
        // ⌘⌥← / ⌘⌥→ cycle tabs.
        if flags.contains(.command), flags.contains(.option),
           !flags.contains(.control) {
            if event.keyCode == BrowserKeyCode.leftArrow || event.keyCode == BrowserKeyCode.rightArrow,
               let session = view.overlays[i].session, session.tabs.count > 1 {
                let delta = event.keyCode == BrowserKeyCode.leftArrow ? -1 : 1
                let n = session.tabs.count
                let next = (session.activeTabIndex + delta + n) % n
                activateBrowserTab(onVT: i, tabIndex: next)
                return true
            }
        }
        // ⌘R reload; ⇧⌘R hard reload (from origin).
        if isCommandChord(event, keyCode: BrowserKeyCode.r, char: "r", allowShift: true) {
            endBrowserAddressEdit(focusWeb: false)
            active?.reload(fromOrigin: flags.contains(.shift))
            return true
        }
        if isCommandChord(event, keyCode: BrowserKeyCode.leftBracket, char: "[") {
            active?.goBack()
            return true
        }
        if isCommandChord(event, keyCode: BrowserKeyCode.rightBracket, char: "]") {
            active?.goForward()
            return true
        }

        // ⌘V / ⌘A / ⌘C only bind to the address bar while it is actively editing.
        // Otherwise leave them for WebKit (page paste / select-all / copy).
        if editing, isCommandChord(event, keyCode: BrowserKeyCode.v, char: "v") {
            if let text = Clipboard.pasteString() {
                insertIntoBrowserAddress(text)
            }
            return true
        }
        if editing, isCommandChord(event, keyCode: BrowserKeyCode.a, char: "a") {
            updateActiveChrome { $0.selectAll() }
            return true
        }
        if editing, isCommandChord(event, keyCode: BrowserKeyCode.c, char: "c") {
            if let chrome = activeChrome {
                let s: String
                if chrome.hasSelection {
                    let a = chrome.address
                    let lo = a.index(a.startIndex, offsetBy: chrome.selLo)
                    let hi = a.index(a.startIndex, offsetBy: chrome.selHi)
                    s = String(a[lo..<hi])
                } else {
                    s = chrome.address
                }
                Clipboard.copyString(s)
            }
            return true
        }

        guard editing else { return false }

        // Address bar typing (first responder is metal view).
        if event.keyCode == 36 { // Return
            commitBrowserAddress()
            return true
        }
        // Tab accepts history completion suffix (selected text).
        if event.keyCode == 48 { // Tab
            acceptHistoryCompletion()
            return true
        }
        if event.keyCode == 51 { // Delete / backspace
            var dismissedCompletion = false
            updateActiveChrome { chrome in
                if chrome.hasSelection {
                    // Drop suggested suffix only; do not re-complete immediately.
                    self.deleteBrowserSelection(&chrome)
                    dismissedCompletion = true
                } else if chrome.caret > 0, !chrome.address.isEmpty {
                    let idx = chrome.address.index(
                        chrome.address.startIndex,
                        offsetBy: chrome.caret - 1
                    )
                    chrome.address.remove(at: idx)
                    chrome.caret -= 1
                    chrome.selAnchor = chrome.caret
                }
            }
            if !dismissedCompletion {
                applyHistoryCompletionIfNeeded()
            }
            return true
        }
        if event.keyCode == 117 { // Forward delete
            updateActiveChrome { chrome in
                if chrome.hasSelection {
                    self.deleteBrowserSelection(&chrome)
                } else if chrome.caret < chrome.address.count {
                    let idx = chrome.address.index(
                        chrome.address.startIndex,
                        offsetBy: chrome.caret
                    )
                    chrome.address.remove(at: idx)
                    chrome.selAnchor = chrome.caret
                }
            }
            return true
        }
        if event.keyCode == 123 { // left
            updateActiveChrome { chrome in
                if flags.contains(.command) {
                    // ⌘← / ⇧⌘←: jump (or select) to start of address.
                    chrome.caret = 0
                    if !flags.contains(.shift) { chrome.selAnchor = 0 }
                } else if flags.contains(.shift) {
                    chrome.caret = max(0, chrome.caret - 1)
                } else if chrome.hasSelection {
                    chrome.caret = chrome.selLo
                    chrome.selAnchor = chrome.caret
                } else {
                    chrome.caret = max(0, chrome.caret - 1)
                    chrome.selAnchor = chrome.caret
                }
            }
            return true
        }
        if event.keyCode == 124 { // right
            // Bare → at start of completion selection accepts the suggestion.
            if !flags.contains(.shift), !flags.contains(.command),
               let chrome = activeChrome,
               chrome.hasSelection, chrome.caret == chrome.selLo, chrome.caret < chrome.selHi {
                acceptHistoryCompletion()
                return true
            }
            updateActiveChrome { chrome in
                if flags.contains(.command) {
                    // ⌘→ / ⇧⌘→: jump (or select) to end of address.
                    chrome.caret = chrome.address.count
                    if !flags.contains(.shift) { chrome.selAnchor = chrome.caret }
                } else if flags.contains(.shift) {
                    chrome.caret = min(chrome.address.count, chrome.caret + 1)
                } else if chrome.hasSelection {
                    chrome.caret = chrome.selHi
                    chrome.selAnchor = chrome.caret
                } else {
                    chrome.caret = min(chrome.address.count, chrome.caret + 1)
                    chrome.selAnchor = chrome.caret
                }
            }
            return true
        }
        // Swallow remaining ⌘/⌃ so they never fall into the PTY as literal chars (e.g. "v").
        // Leave VT-switch chords for routeKey (⌘1… / ⇧⌘[ ]).
        if flags.contains(.command) || flags.contains(.control) {
            if let manager = view.manager,
               KeyBridge.vtSwitchIndex(from: event, vtCount: manager.config.vtCount) != nil {
                return false
            }
            if KeyBridge.vtSwitchDelta(from: event) != nil {
                return false
            }
            return true
        }
        // Prefer `characters` for typing (respects shift for symbols); ignore modifiers already filtered.
        if let chars = event.characters, !chars.isEmpty {
            let filtered = chars.filter { ch in
                guard ch.isASCII, !ch.isNewline else { return false }
                // Drop control characters (C0 / DEL); keep printable ASCII.
                guard let u = ch.unicodeScalars.first else { return false }
                return u.value >= 0x20 && u.value != 0x7F
            }
            if !filtered.isEmpty {
                insertIntoBrowserAddress(String(filtered))
            }
            return true
        }
        return true
    }

    func browserFindHUDLayout(cols: Int) -> SearchHUDLayout {
        let needle = activeSession?.findNeedle ?? ""
        let hasMatch = activeSession?.findHasMatch ?? true
        guard cols > 0 else {
            return SearchHUDLayout(line: "/", caretCol: 1, upCol: -1, downCol: -1)
        }
        let status = (!needle.isEmpty && !hasMatch) ? "0" : ""
        let nav = "↑ ↓"
        let right = status.isEmpty ? (" " + nav) : (" " + status + " " + nav)
        let rightCols = OverlayCells.columnCount(right)
        let leftBudget = max(1, cols - rightCols)
        let slashCols = OverlayCells.columnCount("/")
        let needleBudget = max(0, leftBudget - slashCols)
        let shown = OverlayCells.prefixFitting(needle, maxCols: needleBudget)
        let left = "/" + shown
        var cells = Array(repeating: " ", count: cols)
        OverlayCells.place(left, at: 0, into: &cells)
        OverlayCells.place(right, at: max(0, cols - rightCols), into: &cells)
        return SearchHUDLayout(
            line: cells.joined(),
            caretCol: min(OverlayCells.columnCount(left), cols - 1),
            upCol: cols >= 3 ? cols - 3 : -1,
            downCol: cols >= 1 ? cols - 1 : -1
        )
    }

    func toggleBrowserFind() {
        guard let session = activeSession else { return }
        if session.findOpen {
            closeBrowserFind()
            return
        }
        endBrowserAddressEdit(focusWeb: false)
        session.findOpen = true
        view.layoutActiveBrowser()
        view.window?.makeFirstResponder(view)
        if !session.findNeedle.isEmpty {
            runBrowserFind()
        }
    }

    func closeBrowserFind() {
        guard let session = activeSession, session.findOpen else { return }
        session.findOpen = false
        view.layoutActiveBrowser()
        active?.focusWebContent()
    }

    func runBrowserFind(backwards: Bool = false) {
        guard let session = activeSession else { return }
        let needle = session.findNeedle
        guard !needle.isEmpty else { return }
        active?.findInPage(needle, backwards: backwards) { [weak self] found in
            DispatchQueue.main.async {
                guard let self, let session = self.activeSession else { return }
                session.findHasMatch = found
                self.view.requestFrame()
            }
        }
    }

    @discardableResult
    func handleBrowserFindTyping(_ event: NSEvent) -> Bool {
        guard let session = activeSession, session.findOpen else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.control) {
            return false
        }
        switch event.keyCode {
        case 36, 76:
            runBrowserFind(backwards: flags.contains(.shift))
            return true
        case 51, 117:
            if !session.findNeedle.isEmpty {
                session.findNeedle.removeLast()
                runBrowserFind()
            }
            return true
        case 126:
            runBrowserFind(backwards: false)
            return true
        case 125:
            runBrowserFind(backwards: true)
            return true
        default:
            break
        }
        if let chars = event.characters {
            var changed = false
            for ch in chars {
                let v = ch.unicodeScalars.first?.value ?? 0
                if v >= 0x20, v != 0x7F, !(v >= 0xF700 && v <= 0xF8FF) {
                    session.findNeedle.append(ch)
                    changed = true
                }
            }
            if changed {
                runBrowserFind()
                return true
            }
        }
        return true
    }

    func deleteBrowserSelection(_ chrome: inout VTBrowserChrome) {
        guard chrome.hasSelection else { return }
        let a = chrome.address
        let lo = a.index(a.startIndex, offsetBy: chrome.selLo)
        let hi = a.index(a.startIndex, offsetBy: chrome.selHi)
        chrome.address.removeSubrange(lo..<hi)
        chrome.caret = chrome.selLo
        chrome.selAnchor = chrome.caret
    }

    func insertIntoBrowserAddress(_ text: String) {
        let cleaned = text
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        guard !cleaned.isEmpty else { return }
        updateActiveChrome { chrome in
            if chrome.hasSelection {
                self.deleteBrowserSelection(&chrome)
            }
            let idx = chrome.address.index(
                chrome.address.startIndex,
                offsetBy: chrome.caret,
                limitedBy: chrome.address.endIndex
            ) ?? chrome.address.endIndex
            chrome.address.insert(contentsOf: cleaned, at: idx)
            chrome.caret += cleaned.count
            chrome.selAnchor = chrome.caret
        }
        applyHistoryCompletionIfNeeded()
    }

    /// If caret is at the end, fill best history match and select the suffix (type-over).
    func applyHistoryCompletionIfNeeded() {
        updateActiveChrome { chrome in
            guard !chrome.hasSelection, chrome.caret == chrome.address.count else { return }
            let typed = chrome.address
            guard let hit = BrowserHistory.shared.completion(for: typed) else { return }
            chrome.address = hit.url
            chrome.caret = min(hit.selectFrom, hit.url.count)
            chrome.selAnchor = hit.url.count
        }
    }

    /// Accept gray-selection completion (caret → end).
    func acceptHistoryCompletion() {
        updateActiveChrome { chrome in
            guard chrome.hasSelection, chrome.caret < chrome.selAnchor else { return }
            chrome.caret = chrome.address.count
            chrome.selAnchor = chrome.caret
        }
    }

    func commitBrowserAddress() {
        guard let chrome = activeChrome else { return }
        // Accept completion selection before commit.
        var s = chrome.address.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return }
        if !s.contains("://") { s = "https://\(s)" }
        guard let url = UntrustedURL(s).embeddableHTTPURL else { return }
        updateActiveChrome {
            $0.editing = false
            $0.address = url.absoluteString
            $0.caret = url.absoluteString.count
            $0.selAnchor = $0.caret
            $0.visibleStart = 0
        }
        addressDragging = false
        active?.load(url: url)
        active?.focusWebContent()
    }
}
