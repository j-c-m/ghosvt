import AppKit
import CGhosttyVT
import Metal
import MetalKit
import QuartzCore
import WebKit

final class MetalTerminalView: MTKView, NSMenuItemValidation {
    var manager: VtManager? {
        didSet {
            overlays.ensure(count: manager?.config.vtCount ?? 0)
            bindSessionRedraws()
        }
    }
    var config: Config = Config()
    /// Display sleep: do not request frames until wake.
    private var screensAsleep = false
    private var blinkWork: DispatchWorkItem?

    var metrics: CellMetrics?
    private var renderer: TerminalRenderer?

    let pad: CGFloat = 4
    var lastCols: UInt16 = 0
    var lastRows: UInt16 = 0
    var lastCellW: UInt32 = 0
    var lastCellH: UInt32 = 0
    private var lastScale: CGFloat = 0
    private var lastFontSize: CGFloat = 0
    /// Font size from config before runtime zoom (⌘0 restores this).
    private var originalFontSize: CGFloat?
    private var lastFrameTime: CFTimeInterval = 0
    private var scrollConfigApplied = false
    private var selecting = false
    private var selectRectangle = false
    /// Any mouse button currently held (for letterbox freeze during app selection).
    private var mouseButtonsHeld: Set<Int> = []
    /// Per-VT search + browser overlays, sized from `vtCount`.
    let overlays = OverlayStore()
    private(set) var search: SearchOverlay!
    private(set) var chrome: BrowserChrome!

    /// ⌘-hover link underline (shell viewport coords).
    private var linkHover: TerminalRenderer.LinkHoverRange?
    /// Last cell used for link-hover resolve (skip full scan while stationary).
    private var lastLinkHoverCell: (col: Int, row: Int)?
    /// Installed only while ⌘ (link hover) or the VT wants mouse motion.
    private var trackingArea: NSTrackingArea?
    /// Last VT mouse-tracking flag used to decide whether a tracking area exists.
    private var lastVtMouseTracking = false

    /// Centered terminal-style quit panel (⌘Q / menu Quit).
    private(set) var isQuitConfirmOpen = false
    private var quitConfirmCompletion: ((Bool) -> Void)?
    /// Focus/screen observers use selector-based `NotificationCenter` registration on `self`.
    private var focusObserversInstalled = false
    private var workspaceObserversInstalled = false
    #if DEBUG
    /// Last logged display range (minInterval, maxInterval, maxFps); skip repeat logs.
    private var lastLoggedDisplay: (minI: CFTimeInterval, maxI: CFTimeInterval, fps: Int)?
    #endif
    /// True while `draw(_:)` is on the stack; `requestFrame` must not recurse.
    private var inDraw = false
    /// One pending present; extra `requestFrame` calls collapse.
    private var framePending = false

    /// Whether the *active* VT has the search HUD open.
    var isSearchOpen: Bool { search.isOpen }

    func ensureOverlays() {
        overlays.ensure(count: manager?.config.vtCount ?? manager?.sessions.count ?? 0)
    }

    private var activeBrowser: EmbeddedBrowserView? { chrome.active }

    /// True while the active VT has an embedded browser (PTY input suspended).
    var isBrowserActive: Bool { chrome.isActive }

    /// True while the stolen find HUD is focused for typing.
    var isBrowserFindOpen: Bool { chrome.isFindOpen }

    /// True while the stolen address bar is focused for typing.
    var isBrowserAddressEditing: Bool { chrome.isAddressEditing }

    override init(frame frameRect: CGRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device)
        commonInit()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        search = SearchOverlay(host: self)
        chrome = BrowserChrome(view: self)
        guard let device else { return }
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        isPaused = true
        enableSetNeedsDisplay = true
        autoResizeDrawable = true
        // Triple-buffer adds a frame of present latency vs Ghostty's tighter queue.
        (layer as? CAMetalLayer)?.maximumDrawableCount = 2
        let bg = DefaultColors.background
        clearColor = MTLClearColor(
            red: Double(bg.r) / 255,
            green: Double(bg.g) / 255,
            blue: Double(bg.b) / 255,
            alpha: 1
        )

        renderer = TerminalRenderer(device: device, pixelFormat: colorPixelFormat, padPoints: pad)
        if renderer == nil {
            fputs("ghosvt: failed to create TerminalRenderer\n", stderr)
        }
        // After renderer exists: Adaptive-Sync range + present pacing.
        applyDisplayRefreshRate()
        installWebExtensionUIHooks()
    }

    /// Wire `BrowserExtensionHost` callbacks into this terminal (macOS 15.4+).
    private func installWebExtensionUIHooks() {
        guard #available(macOS 15.4, *) else { return }
        let host = BrowserExtensionHost.shared
        host.ui = BrowserExtensionHost.UIHooks(
            activeVTIndex: { [weak self] in
                self?.manager?.activeIndex ?? 0
            },
            focusVT: { [weak self] vt in
                guard let self, let manager = self.manager else { return }
                if manager.activeIndex != vt {
                    manager.switchTo(vt)
                    self.afterVtSwitch(manager: manager)
                }
            },
            dismissBrowser: { [weak self] vt in
                self?.chrome.dismissBrowser(onVT: vt)
            },
            openOrNavigate: { [weak self] url, vt in
                self?.chrome.openBrowser(url: url, onVT: vt)
            },
            openNewTab: { [weak self] url, vt in
                self?.chrome.openNewBrowserTab(url: url, onVT: vt, activate: true, editAddress: false)
            },
            activateTab: { [weak self] vt, tabIndex in
                self?.chrome.activateBrowserTab(onVT: vt, tabIndex: tabIndex)
            },
            closeTab: { [weak self] vt, tabIndex in
                self?.chrome.closeBrowserTab(onVT: vt, tabIndex: tabIndex)
            },
            freeVTIndex: { [weak self] in
                guard let self else { return nil }
                self.ensureOverlays()
                return self.overlays.enumerated().first(where: { $0.element.session == nil })?.offset
            },
            contentFrameInScreen: { [weak self] vt in
                guard let self else { return .null }
                self.ensureOverlays()
                guard vt >= 0, vt < self.overlays.count,
                      let browser = self.overlays[vt].session?.activeBrowser,
                      let win = browser.window
                else { return .null }
                let rect = browser.convert(browser.bounds, to: nil)
                return win.convertToScreen(rect)
            },
            isAppFullscreen: { [weak self] in
                self?.window?.styleMask.contains(.fullScreen) == true
            },
            presentActionPopup: { [weak self] action, completion in
                self?.chrome.presentExtensionActionPopup(action, completion: completion)
            },
            onActionDidUpdate: { [weak self] in
                DispatchQueue.main.async {
                    self?.chrome.refreshExtensionToolbarCacheAndButtons()
                }
            }
        )
    }

    /// Configure MTKView + Metal for true Adaptive-Sync (or fixed-rate pacing).
    ///
    /// - `preferredFramesPerSecond`: allow draws up to max Hz.
    /// - `present(_:afterMinimumDuration:)` (in the renderer): hold each frame within
    ///   `[minimumRefreshInterval, maximumRefreshInterval]` so VRR panels can vary rate.
    /// Fullscreen is required for Adaptive-Sync on macOS (app enters FS at launch).
    private func applyDisplayRefreshRate() {
        let screen = window?.screen ?? NSScreen.main
        var minInterval: CFTimeInterval = 1.0 / 60.0
        var maxInterval: CFTimeInterval = 1.0 / 60.0
        var maxFps = 60

        if let screen {
            let minI = screen.minimumRefreshInterval
            let maxI = screen.maximumRefreshInterval
            if minI > 0, minI.isFinite { minInterval = minI }
            if maxI > 0, maxI.isFinite { maxInterval = maxI }
            if maxInterval < minInterval {
                swap(&minInterval, &maxInterval)
            }

            // Prefer the higher of the two APIs — external 144 Hz panels and
            // ProMotion sometimes disagree on which field is authoritative.
            let fromMax = screen.maximumFramesPerSecond
            if fromMax > 0 { maxFps = max(maxFps, fromMax) }
            let fromInterval = Int((1.0 / minInterval).rounded())
            if fromInterval > 0 { maxFps = max(maxFps, fromInterval) }
        }

        // Draw callback at the panel’s ceiling; present duration paces Adaptive-Sync.
        preferredFramesPerSecond = max(1, maxFps)

        renderer?.configureDisplay(minInterval: minInterval, maxInterval: maxInterval)

        #if DEBUG
        let next = (minI: minInterval, maxI: maxInterval, fps: maxFps)
        if let prev = lastLoggedDisplay,
           abs(prev.minI - next.minI) < 1e-9,
           abs(prev.maxI - next.maxI) < 1e-9,
           prev.fps == next.fps {
            return
        }
        lastLoggedDisplay = next

        let adaptive = maxInterval > minInterval * 1.01
        let minFpsLog = Int((1.0 / maxInterval).rounded())
        if adaptive {
            fputs(
                "ghosvt: Adaptive-Sync \(minFpsLog)–\(maxFps) Hz (present afterMinimumDuration)\n",
                stderr
            )
        } else {
            fputs("ghosvt: display \(maxFps) Hz fixed (paced present)\n", stderr)
        }
        #endif
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeFocusObservers()
        removeWorkspaceObservers()
        restorePreferredFirstResponder()
        rebindDisplay()
        spawnIfNeeded()
        updateTrackingAreas()
        if window != nil {
            installFocusObservers()
            installWorkspaceObservers()
        }
        bindSessionRedraws()
        requestFrame()
    }

    /// Browser open + address idle → WebView; address editing → metal; else metal (PTY).
    private func restorePreferredFirstResponder() {
        if isBrowserActive {
            if isBrowserAddressEditing || isBrowserFindOpen {
                window?.makeFirstResponder(self)
            } else {
                activeBrowser?.focusWebContent()
            }
        } else {
            window?.makeFirstResponder(self)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        // Something focused metal while the page should own keys — bounce to WebView.
        // Skip when address bar or find HUD is using metal as first responder.
        if ok, isBrowserActive, !isBrowserAddressEditing, !isBrowserFindOpen {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isBrowserActive,
                      !self.isBrowserAddressEditing, !self.isBrowserFindOpen else { return }
                guard self.window?.firstResponder === self else { return }
                self.activeBrowser?.focusWebContent()
            }
        }
        return ok
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
            self.trackingArea = nil
        }
        let vtTracking = manager?.active.isMouseTracking() ?? false
        lastVtMouseTracking = vtTracking
        // A full-view area makes AppKit walk _NSTrackingAreaAKManager on every
        // mouse packet. Idle getty does not need that.
        guard NSEvent.modifierFlags.contains(.command) || vtTracking else { return }
        let opts: NSTrackingArea.Options = [
            .activeInKeyWindow,
            .mouseEnteredAndExited,
            .mouseMoved,
            .inVisibleRect,
            .enabledDuringMouseDrag,
        ]
        let area = NSTrackingArea(rect: bounds, options: opts, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    private func removeFocusObservers() {
        guard focusObserversInstalled else { return }
        let nc = NotificationCenter.default
        nc.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        nc.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        nc.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: nil)
        focusObserversInstalled = false
    }

    private func removeWorkspaceObservers() {
        guard workspaceObserversInstalled else { return }
        let nc = NSWorkspace.shared.notificationCenter
        nc.removeObserver(self, name: NSWorkspace.screensDidSleepNotification, object: nil)
        nc.removeObserver(self, name: NSWorkspace.screensDidWakeNotification, object: nil)
        nc.removeObserver(self, name: NSWorkspace.didWakeNotification, object: nil)
        workspaceObserversInstalled = false
    }

    private func installFocusObservers() {
        removeFocusObservers()
        guard let window else { return }
        let nc = NotificationCenter.default
        // Selector observers stay on the main actor (MTKView); avoid @Sendable block captures.
        nc.addObserver(
            self,
            selector: #selector(handleWindowDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
        nc.addObserver(
            self,
            selector: #selector(handleWindowDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
        nc.addObserver(
            self,
            selector: #selector(handleWindowDidChangeScreen),
            name: NSWindow.didChangeScreenNotification,
            object: window
        )
        focusObserversInstalled = true
    }

    private func installWorkspaceObservers() {
        removeWorkspaceObservers()
        let nc = NSWorkspace.shared.notificationCenter
        // Pause only when displays actually sleep — not willSleep (can cancel).
        nc.addObserver(
            self,
            selector: #selector(handleScreensDidSleep),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        // Both wake paths may fire; resumeAfterSleep gates on isPaused.
        nc.addObserver(
            self,
            selector: #selector(handleScreensDidWake),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
        nc.addObserver(
            self,
            selector: #selector(handleSystemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        workspaceObserversInstalled = true
    }

    @objc private func handleWindowDidBecomeKey(_ note: Notification) {
        manager?.active.encodeFocus(gained: true)
        requestFrame()
    }

    @objc private func handleWindowDidResignKey(_ note: Notification) {
        manager?.active.encodeFocus(gained: false)
        blinkWork?.cancel()
        requestFrame()
    }

    @objc private func handleWindowDidChangeScreen(_ note: Notification) {
        rebindDisplay()
    }

    @objc private func handleScreensDidSleep(_ note: Notification) {
        screensAsleep = true
        isPaused = true
    }

    @objc private func handleScreensDidWake(_ note: Notification) {
        resumeAfterSleep()
    }

    @objc private func handleSystemDidWake(_ note: Notification) {
        resumeAfterSleep()
    }

    /// Adaptive-Sync + HiDPI metrics + resize all live VTs (SIGWINCH).
    private func rebindDisplay() {
        applyDisplayRefreshRate()
        refreshMetrics(force: true)
        applyResize()
    }

    /// Idempotent: second wake notification is a no-op if already resumed.
    private func resumeAfterSleep() {
        guard screensAsleep else { return }
        screensAsleep = false
        rebindDisplay()
        requestFrame()
    }

    /// Ask for a present. Safe to call from any thread, the key monitor, or `draw`.
    /// Extra calls in the same turn become one frame after the current stack returns.
    nonisolated func requestFrame() {
        if Thread.isMainThread {
            MainActor.assumeIsolated { self.scheduleFrame() }
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.scheduleFrame()
        }
    }

    private func scheduleFrame() {
        guard !screensAsleep else { return }
        needsDisplay = true
        guard !framePending else { return }
        framePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.framePending = false
            self.flushFrameRequest()
        }
    }

    private func flushFrameRequest() {
        guard !screensAsleep else { return }
        needsDisplay = true
        guard !inDraw else { return }
        draw()
    }

    private func bindSessionRedraws() {
        guard let manager else { return }
        for s in manager.sessions {
            s.onNeedsRedraw = { [weak self] in
                self?.requestFrame()
            }
        }
    }

    private func scheduleBlinkIfNeeded() {
        blinkWork?.cancel()
        guard let renderer, let rs = manager?.active.renderState else { return }
        var blinking = false
        _ = ghostty_render_state_get(rs, GHOSTTY_RENDER_STATE_DATA_CURSOR_BLINKING, &blinking)
        var visible = false
        _ = ghostty_render_state_get(rs, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE, &visible)
        guard blinking, visible else { return }
        let period = max(renderer.blinkPeriod, 0.05)
        let t = CACurrentMediaTime()
        let delay = max(0.001, (floor(t / period) + 1) * period - t)
        let work = DispatchWorkItem { [weak self] in self?.requestFrame() }
        blinkWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        refreshMetrics(force: false)
        spawnIfNeeded()
        applyResize()
        requestFrame()
    }

    private func refreshMetrics(force: Bool) {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        if !force,
           abs(scale - lastScale) < 0.001,
           abs(config.fontSize - lastFontSize) < 0.001,
           metrics != nil {
            return
        }
        metrics = CellMetrics.measure(fontSize: config.fontSize, scale: scale)
        lastScale = scale
        lastFontSize = config.fontSize
        renderer?.resetAtlas()
    }

    /// Terminal area in view points (≤ max-aspect, centered).
    func contentRectPoints() -> CGRect {
        ContentLayout.contentRect(in: bounds.size, maxAspect: config.maxAspect)
    }

    /// Full cell grid that fits the content rect (includes the search row when open).
    func fullGridSize() -> (cols: UInt16, rows: UInt16, cellW: UInt32, cellH: UInt32)? {
        guard let metrics else { return nil }
        let content = contentRectPoints()
        let cols = max(1, Int((content.width - 2 * pad) / metrics.cellWidth))
        let rows = max(1, Int((content.height - 2 * pad) / metrics.cellHeight))
        return (
            UInt16(cols),
            UInt16(rows),
            UInt32(metrics.cellWidthPx),
            UInt32(metrics.cellHeightPx)
        )
    }

    /// Shell PTY size: one fewer row while search steals a full-grid row for the HUD.
    private func shellGridSize() -> (cols: UInt16, rows: UInt16, cellW: UInt32, cellH: UInt32)? {
        guard var g = fullGridSize() else { return nil }
        if isSearchOpen {
            g.rows = max(1, g.rows - 1)
        }
        return g
    }

    private func spawnIfNeeded() {
        guard let manager, let g = shellGridSize() else { return }
        manager.ensureActiveStarted(cols: g.cols, rows: g.rows, cellWidthPx: g.cellW, cellHeightPx: g.cellH)
        lastCols = g.cols
        lastRows = g.rows
        lastCellW = g.cellW
        lastCellH = g.cellH
    }

    /// Push cols/rows and cell pixel size to live VTs.
    /// Each VT that has search open is one row shorter; others use the full grid.
    func applyResize() {
        guard let manager, let full = fullGridSize() else { return }
        ensureOverlays()
        let fullRows = full.rows
        for (i, session) in manager.sessions.enumerated() where session.isLive {
            let open = i < overlays.count && overlays[i].search.isOpen
            let rows = open ? max(1, fullRows - 1) : fullRows
            session.resize(
                cols: full.cols,
                rows: rows,
                cellWidthPx: full.cellW,
                cellHeightPx: full.cellH
            )
        }
        if let g = shellGridSize() {
            lastCols = g.cols
            lastRows = g.rows
            lastCellW = g.cellW
            lastCellH = g.cellH
        }
        requestFrame()
    }

    override func draw(_ dirtyRect: NSRect) {
        inDraw = true
        defer { inDraw = false }
        guard let renderer,
              let manager,
              let metrics
        else { return }

        if !scrollConfigApplied {
            for s in manager.sessions {
                s.applyScrollConfig(config)
            }
            scrollConfigApplied = true
        }

        // Drain PTY for all VTs so buffers don't block; skip scroll/indicator
        // work on the VT that is covered by the browser (sleep that surface).
        manager.pollAllIO()
        let vtTracking = manager.active.isMouseTracking()
        if vtTracking != lastVtMouseTracking {
            updateTrackingAreas()
        }

        let now = CACurrentMediaTime()
        let dt = lastFrameTime > 0 ? now - lastFrameTime : 1.0 / 60.0
        lastFrameTime = now

        let browserVT = manager.activeIndex
        let browserSleepsActive = activeBrowser != nil
        var scrollLive = false
        for (i, s) in manager.sessions.enumerated() where s.isLive {
            if browserSleepsActive, i == browserVT { continue }
            if s.stepScroll(dt: dt) { scrollLive = true }
        }

        let indicator = browserSleepsActive ? nil : manager.tickIndicator()
        let scale = window?.backingScaleFactor ?? 2
        // Content rect in drawable pixels (same aspect cap as grid sizing).
        // Snap in drawable pixels so the cell grid lands on whole framebuffer pixels.
        let contentPx = ContentLayout.contentRect(
            in: drawableSize,
            maxAspect: config.maxAspect,
            snapPixels: true
        )
        let visualOffset = manager.active.visualOffsetRows()

        let searchHL = search.viewportHighlights(session: manager.active)
        let hudLayout = isSearchOpen ? search.hudLayout(cols: Int(lastCols)) : nil
        let focused = window?.isKeyWindow == true

        if activeBrowser == nil,
           !renderer.needsRedraw(
            session: manager.active,
            metrics: metrics,
            drawableSize: drawableSize,
            contentRect: contentPx,
            scale: scale,
            indicator: indicator,
            visualOffsetRows: visualOffset,
            searchHighlights: searchHL,
            searchHUD: hudLayout?.line,
            linkHover: linkHover,
            quitConfirm: isQuitConfirmOpen,
            windowFocused: focused
           ) {
            if scrollLive { requestFrame() }
            if focused { scheduleBlinkIfNeeded() }
            return
        }

        guard let drawable = currentDrawable,
              let rpd = currentRenderPassDescriptor
        else { return }

        if activeBrowser != nil {
            // Stolen top row(s): address bar (+ tab strip when multi-tab).
            // Do not reuse the previous VT's FS-TUI letterbox / edge sample — browser
            // chrome owns the surface and borders reset to host defaults.
            let cols = max(1, Int(lastCols))
            let bar = chrome.browserHUDLayout(cols: cols)
            let strip = chrome.browserTabStripLayout(cols: cols)
            let defBg = DefaultColors.background
            let defFg = DefaultColors.foreground
            let letterboxBg = DefaultColors.background
            let editing = isBrowserAddressEditing
            let caretOn: Bool
            if editing || isBrowserFindOpen, let rs = manager.active.renderState {
                caretOn = renderer.cursorBlinkOn(renderState: rs)
            } else {
                caretOn = editing || isBrowserFindOpen
            }
            let findHUD = isBrowserFindOpen ? chrome.browserFindHUDLayout(cols: cols) : nil
            renderer.presentBrowserChrome(
                drawable: drawable,
                renderPassDescriptor: rpd,
                drawableSize: drawableSize,
                contentRect: contentPx,
                scale: scale,
                metrics: metrics,
                cols: cols,
                line: bar.line,
                caretCol: bar.caretCol,
                showCaret: editing && caretOn && !bar.hasSelection,
                letterboxBg: letterboxBg,
                defFg: defFg,
                defBg: defBg,
                selStartCol: bar.selStartCol,
                selEndCol: bar.selEndCol,
                tabStripLine: strip?.line,
                tabActiveStartCol: strip?.activeStart ?? -1,
                tabActiveEndCol: strip?.activeEnd ?? -1,
                findLine: findHUD?.line,
                findCaretCol: findHUD?.caretCol ?? 0,
                findShowCaret: isBrowserFindOpen && caretOn,
                quitConfirm: isQuitConfirmOpen,
                quitLayoutRows: max(1, Int(lastRows))
            )
            syncLetterboxChrome(bg: letterboxBg)
            // Frames only — host is not queried on the paint path.
            chrome.layoutExtensionActionButtons(layout: bar)
        } else {
            chrome.hideExtensionActionButtons()
            renderer.draw(
                session: manager.active,
                metrics: metrics,
                drawable: drawable,
                renderPassDescriptor: rpd,
                drawableSize: drawableSize,
                contentRect: contentPx,
                scale: scale,
                indicator: indicator,
                clearColor: clearColor,
                visualOffsetRows: visualOffset,
                fontLigatures: config.fontLigatures,
                searchHighlights: searchHL,
                searchHUD: hudLayout?.line,
                searchCaretCol: hudLayout?.caretCol ?? 0,
                searchHUDAtTop: config.searchPosition == .top,
                freezeLetterbox: !mouseButtonsHeld.isEmpty || selecting,
                linkHover: linkHover,
                quitConfirm: isQuitConfirmOpen,
                windowFocused: focused
            )
            syncLetterboxChrome(bg: renderer.lastLetterboxBg)
        }
        // Only when browser is up — avoid per-frame frame writes when idle.
        if activeBrowser != nil {
            layoutActiveBrowser()
        }
        if scrollLive { requestFrame() }
        if focused { scheduleBlinkIfNeeded() }
    }

    /// Map a view click to a cell in the full content grid (includes stolen search row).
    func fullGridCell(at event: NSEvent) -> (col: Int, row: Int)? {
        guard let metrics, let full = fullGridSize() else { return nil }
        let content = contentRectPoints()
        let viewPoint = convert(event.locationInWindow, from: nil)
        let yFromTop = bounds.height - viewPoint.y
        let localX = viewPoint.x - content.minX - pad
        let localY = yFromTop - content.minY - pad
        guard localX >= 0, localY >= 0 else { return nil }
        let col = Int(localX / metrics.cellWidth)
        let row = Int(localY / metrics.cellHeight)
        guard col >= 0, row >= 0, col < Int(full.cols), row < Int(full.rows) else {
            return nil
        }
        return (col, row)
    }

    /// Keep MTKView clear + window chrome in lockstep with letterbox / content bg.
    private func syncLetterboxChrome(bg: GhosttyColorRgb) {
        let next = MTLClearColor(
            red: Double(bg.r) / 255,
            green: Double(bg.g) / 255,
            blue: Double(bg.b) / 255,
            alpha: 1
        )
        let eps = 1.0 / 512.0
        if abs(clearColor.red - next.red) > eps
            || abs(clearColor.green - next.green) > eps
            || abs(clearColor.blue - next.blue) > eps {
            clearColor = next
            window?.backgroundColor = NSColor(
                srgbRed: CGFloat(bg.r) / 255,
                green: CGFloat(bg.g) / 255,
                blue: CGFloat(bg.b) / 255,
                alpha: 1
            )
        }
    }

    // MARK: - Input

    override func scrollWheel(with event: NSEvent) {
        requestFrame()
        // Browser owns scroll (WebView) while open.
        if activeBrowser != nil {
            super.scrollWheel(with: event)
            return
        }
        guard let manager, let metrics else {
            super.scrollWheel(with: event)
            return
        }
        let session = manager.active
        guard session.isLive else { return }

        // Apps with mouse tracking own the wheel (encode as buttons 4–7).
        if session.isMouseTracking() {
            if let surface = makeMouseSurface(event) {
                let mods = KeyBridge.mapMods(event.modifierFlags)
                if abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX),
                   abs(event.scrollingDeltaY) > 0.01 {
                    session.encodeWheel(
                        vertical: true,
                        positive: event.scrollingDeltaY > 0,
                        surface: surface,
                        mods: mods
                    )
                } else if abs(event.scrollingDeltaX) > 0.01 {
                    session.encodeWheel(
                        vertical: false,
                        positive: event.scrollingDeltaX > 0,
                        surface: surface,
                        mods: mods
                    )
                }
            }
            return
        }

        let dy: CGFloat
        if event.hasPreciseScrollingDeltas {
            dy = event.scrollingDeltaY
        } else {
            // Classic wheel: each notch ≈ 3 lines.
            dy = event.scrollingDeltaY * metrics.cellHeight * 3
        }
        // Positive scrollingDeltaY = content moves down = older history.
        let deltaRows = Double(dy) / Double(max(metrics.cellHeight, 1))
        if session.encodeAlternateScroll(deltaRows: deltaRows) { return }
        session.applyScrollImpulse(deltaRows: deltaRows)
    }

    // MARK: - Selection / mouse

    private func makeSelectionHit(_ event: NSEvent) -> TerminalSession.SelectionHit? {
        guard let manager, let metrics else { return nil }
        let scale = window?.backingScaleFactor ?? 2
        // When search steals the top row, shell cells sit one row lower.
        var content = contentRectPoints()
        if isSearchOpen, config.searchPosition == .top {
            content.origin.y += metrics.cellHeight
            content.size.height = max(0, content.size.height - metrics.cellHeight)
        }
        return manager.active.selectionHit(
            viewPoint: convert(event.locationInWindow, from: nil),
            viewSize: bounds.size,
            contentRectPoints: content,
            cellWidthPoints: metrics.cellWidth,
            cellHeightPoints: metrics.cellHeight,
            padPoints: pad,
            scale: scale
        )
    }

    /// Content-relative surface geometry for mouse encoding (pixels, top-left).
    private func makeMouseSurface(_ event: NSEvent) -> TerminalSession.MouseSurface? {
        guard let metrics else { return nil }
        let scale = window?.backingScaleFactor ?? 2
        var content = contentRectPoints()
        var padTopPoints = pad
        // Match shell paint: search at top shifts the grid down one cell.
        if isSearchOpen, config.searchPosition == .top {
            content.origin.y += metrics.cellHeight
            content.size.height = max(0, content.size.height - metrics.cellHeight)
            padTopPoints = pad // still pad inside the shell content rect
        }
        let viewPoint = convert(event.locationInWindow, from: nil)
        let yFromTop = bounds.height - viewPoint.y
        let posX = Float((viewPoint.x - content.minX) * scale)
        let posY = Float((yFromTop - content.minY) * scale)
        return TerminalSession.MouseSurface(
            posX: posX,
            posY: posY,
            screenWidth: UInt32(max(1, (content.width * scale).rounded())),
            screenHeight: UInt32(max(1, (content.height * scale).rounded())),
            cellWidth: UInt32(metrics.cellWidthPx),
            cellHeight: UInt32(metrics.cellHeightPx),
            padLeft: UInt32(max(0, (pad * scale).rounded())),
            padTop: UInt32(max(0, (padTopPoints * scale).rounded()))
        )
    }

    /// Host selection when not in mouse-tracking mode, or always with Shift.
    private func shouldHostSelect(_ event: NSEvent) -> Bool {
        guard let manager else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.shift) { return true }
        return !manager.active.isMouseTracking()
    }

    private func sendAppMouse(
        _ event: NSEvent,
        action: GhosttyMouseAction,
        button: GhosttyMouseButton?
    ) {
        guard let manager, let surface = makeMouseSurface(event) else { return }
        _ = manager.active.encodeMouse(
            action: action,
            button: button,
            surface: surface,
            mods: KeyBridge.mapMods(event.modifierFlags),
            buttonNumber: button == nil ? nil : event.buttonNumber
        )
    }

    override func mouseDown(with event: NSEvent) {
        requestFrame()
        noteMouseDown(event)
        // Browser mode: only address-bar HUD; WebView receives the rest via hit-test.
        if activeBrowser != nil {
            if event.buttonNumber == 0, chrome.handleBrowserHUDClick(event) {
                return
            }
            // Not on HUD → let the event fall through to the WebView (don't send to PTY).
            return
        }
        if event.buttonNumber == 0, search.handleRowClick(event) {
            return
        }
        // ⌘-click: open URL in embedded browser (does not steal from app mouse tracking).
        if event.buttonNumber == 0, handleLinkCmdClick(event) {
            return
        }
        guard let manager, event.buttonNumber == 0 else {
            super.mouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        if shouldHostSelect(event), let hit = makeSelectionHit(event) {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            selectRectangle = flags.contains(.option)
            selecting = true
            let timeNs = UInt64(event.timestamp * 1_000_000_000)
            manager.active.selectionPress(hit: hit, timeNs: timeNs, rectangle: selectRectangle)
            return
        }
        selecting = false
        if manager.active.isMouseTracking() {
            sendAppMouse(event, action: GHOSTTY_MOUSE_ACTION_PRESS, button: GHOSTTY_MOUSE_BUTTON_LEFT)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        requestFrame()
        if activeBrowser != nil {
            if chrome.addressDragging {
                chrome.handleBrowserAddressDrag(event)
            }
            return
        }
        if selecting, let manager, let hit = makeSelectionHit(event) {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            selectRectangle = flags.contains(.option)
            _ = manager.active.selectionDrag(hit: hit, rectangle: selectRectangle)
            return
        }
        if let manager, manager.active.isMouseTracking() {
            sendAppMouse(event, action: GHOSTTY_MOUSE_ACTION_MOTION, button: GHOSTTY_MOUSE_BUTTON_LEFT)
            return
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        requestFrame()
        noteMouseUp(event)
        if activeBrowser != nil {
            if chrome.addressDragging {
                chrome.handleBrowserAddressDrag(event)
                chrome.addressDragging = false
            }
            return
        }
        if selecting, let manager {
            selecting = false
            manager.active.selectionRelease(hit: makeSelectionHit(event))
            if config.copyOnSelect {
                _ = manager.active.copySelectionToPasteboard()
            }
            return
        }
        if let manager, manager.active.isMouseTracking() {
            sendAppMouse(event, action: GHOSTTY_MOUSE_ACTION_RELEASE, button: GHOSTTY_MOUSE_BUTTON_LEFT)
            return
        }
        super.mouseUp(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        requestFrame()
        if activeBrowser != nil {
            // No link hover / PTY mouse while browser owns the VT.
            return
        }
        updateLinkHover(with: event)
        if let manager, manager.active.isMouseTracking(), !selecting {
            // Still track links under ⌘; app also gets motion when not selecting.
            if !event.modifierFlags.contains(.command) {
                sendAppMouse(event, action: GHOSTTY_MOUSE_ACTION_MOTION, button: nil)
                return
            }
            // ⌘ held: don't feed motion to app (hover UI for open-link).
            return
        }
        super.mouseMoved(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        requestFrame()
        noteMouseDown(event)
        if activeBrowser != nil { return }
        if let manager, manager.active.isMouseTracking(), !shouldHostSelect(event) {
            sendAppMouse(event, action: GHOSTTY_MOUSE_ACTION_PRESS, button: GHOSTTY_MOUSE_BUTTON_RIGHT)
            return
        }
        super.rightMouseDown(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        requestFrame()
        noteMouseUp(event)
        if activeBrowser != nil { return }
        if let manager, manager.active.isMouseTracking() {
            sendAppMouse(event, action: GHOSTTY_MOUSE_ACTION_RELEASE, button: GHOSTTY_MOUSE_BUTTON_RIGHT)
            return
        }
        super.rightMouseUp(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        requestFrame()
        if activeBrowser != nil { return }
        if let manager, manager.active.isMouseTracking() {
            sendAppMouse(event, action: GHOSTTY_MOUSE_ACTION_MOTION, button: GHOSTTY_MOUSE_BUTTON_RIGHT)
            return
        }
        super.rightMouseDragged(with: event)
    }

    private func noteMouseDown(_ event: NSEvent) {
        mouseButtonsHeld.insert(event.buttonNumber)
    }

    private func noteMouseUp(_ event: NSEvent) {
        mouseButtonsHeld.remove(event.buttonNumber)
    }

    override func otherMouseDown(with event: NSEvent) {
        requestFrame()
        noteMouseDown(event)
        if activeBrowser != nil { return }
        // Middle button: app when tracking, else paste.
        guard event.buttonNumber == 2, let manager else {
            super.otherMouseDown(with: event)
            return
        }
        if manager.active.isMouseTracking() {
            sendAppMouse(event, action: GHOSTTY_MOUSE_ACTION_PRESS, button: GHOSTTY_MOUSE_BUTTON_MIDDLE)
            return
        }
        if let text = Clipboard.pasteString() {
            manager.active.pasteText(text)
        }
    }

    override func otherMouseUp(with event: NSEvent) {
        requestFrame()
        noteMouseUp(event)
        if activeBrowser != nil { return }
        if event.buttonNumber == 2, let manager, manager.active.isMouseTracking() {
            sendAppMouse(event, action: GHOSTTY_MOUSE_ACTION_RELEASE, button: GHOSTTY_MOUSE_BUTTON_MIDDLE)
            return
        }
        super.otherMouseUp(with: event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        requestFrame()
        if activeBrowser != nil { return }
        if event.buttonNumber == 2, let manager, manager.active.isMouseTracking() {
            sendAppMouse(event, action: GHOSTTY_MOUSE_ACTION_MOTION, button: GHOSTTY_MOUSE_BUTTON_MIDDLE)
            return
        }
        super.otherMouseDragged(with: event)
    }

    /// Single key policy for the local monitor, `keyDown`, and `performKeyEquivalent`.
    enum KeyDisposition {
        /// Handled here; swallow the event.
        case consumed
        /// Let the embedded page / WebView see the event.
        case toWebView
        /// Leave to the menu / system equivalent.
        case toMenu
        /// Fed to the PTY (not a Command leftover).
        case toPty
    }

    /// One priority list for every key-down entry. Performs host side effects.
    @discardableResult
    func routeKey(_ event: NSEvent) -> KeyDisposition {
        requestFrame()
        guard event.type == .keyDown else { return .toMenu }
        if handleQuitConfirmKey(event) { return .consumed }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)

        if isBrowserActive {
            if command {
                if handleFontSizeKeys(event) { return .consumed }
                // VT switch before address-bar swallow (⌘1… / ⇧⌘[ ] must leave a page).
                if let manager, handleVtSwitch(event, manager: manager) { return .consumed }
                if chrome.handleBrowserKeys(event) { return .consumed }
                if chrome.handleBrowserPageEditKeys(event) { return .consumed }
                if chrome.handleBrowserPageScrollKeys(event) { return .consumed }
                // Do not claim leftover ⌘ — WebKit / the Edit menu may want it.
                return .toWebView
            }
            if chrome.handleBrowserKeys(event) { return .consumed }
            if isBrowserAddressEditing || isBrowserFindOpen { return .consumed }
            if chrome.handleBrowserPageScrollKeys(event) { return .consumed }
            return .toWebView
        }

        if command, event.charactersIgnoringModifiers?.lowercased() == "q" {
            NSApp.terminate(nil)
            return .consumed
        }

        if chrome.handleBrowserKeys(event) { return .consumed }
        if handleFontSizeKeys(event) { return .consumed }
        if search.handleKeys(event) { return .consumed }
        if isSearchOpen, search.handleTyping(event) { return .consumed }
        if let manager, handleVtSwitch(event, manager: manager) { return .consumed }
        if let manager, handleScrollPage(event, manager: manager) { return .consumed }
        if let manager, handleTerminalChords(event, manager: manager) { return .consumed }

        if command {
            if !flags.contains(.control), !flags.contains(.option) {
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "c":
                    _ = manager?.active.copySelectionToPasteboard()
                    return .consumed
                case "v":
                    if let manager, let text = Clipboard.pasteString() {
                        manager.active.pasteText(text)
                    }
                    return .consumed
                default:
                    break
                }
            }
            return .toMenu
        }

        feedPty(event)
        return .toPty
    }

    private func feedPty(_ event: NSEvent) {
        guard let manager else { return }
        if manager.active.selectionActive {
            manager.active.clearSelection()
        }
        KeyBridge.handleKeyDown(event, session: manager.active)
    }

    override func keyDown(with event: NSEvent) {
        guard manager != nil else {
            super.keyDown(with: event)
            return
        }
        if routeKey(event) == .toWebView {
            activeBrowser?.forwardKeyDown(event)
        }
    }

    @discardableResult
    func handleVtSwitch(_ event: NSEvent, manager: VtManager) -> Bool {
        if let idx = KeyBridge.vtSwitchIndex(from: event, vtCount: manager.config.vtCount) {
            manager.switchTo(idx)
            afterVtSwitch(manager: manager)
            return true
        }
        if let delta = KeyBridge.vtSwitchDelta(from: event) {
            manager.switchByDelta(delta)
            afterVtSwitch(manager: manager)
            return true
        }
        return false
    }

    /// Activate the new VT; restore that VT’s search HUD / browser if open.
    private func afterVtSwitch(manager: VtManager) {
        search.cancelDebounce()
        ensureOverlays()
        // Per-VT open flag drives shell size for every session.
        applyResize()
        if let g = shellGridSize() {
            manager.ensureActiveStarted(
                cols: g.cols, rows: g.rows,
                cellWidthPx: g.cellW, cellHeightPx: g.cellH
            )
        }
        // Refresh matches against this session’s scrollback (coords can drift).
        if isSearchOpen, !search.needle.isEmpty {
            search.run(needle: search.needle, selectFirst: false)
        }
        chrome.showBrowserForActiveVT()
        if isBrowserAddressEditing || isBrowserFindOpen {
            window?.makeFirstResponder(self)
        } else if let browser = activeBrowser {
            browser.focusWebContent()
        } else {
            window?.makeFirstResponder(self)
        }
        if #available(macOS 15.4, *) {
            BrowserExtensionHost.shared.focusChanged(toVT: manager.activeIndex)
        }
    }

    // MARK: - Embedded browser (⌘-click links)

    /// ⌘-click a cell → OSC 8 or bare http(s). Embed when enabled; else system browser.
    @discardableResult
    private func handleLinkCmdClick(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command),
              !flags.contains(.option),
              !flags.contains(.control)
        else { return false }
        guard let manager, let cell = fullGridCell(at: event) else { return false }
        guard let shellRow = shellViewportRow(fromFullRow: cell.row) else { return false }
        guard let url = manager.active.embeddableURLAtViewport(
            col: UInt16(cell.col),
            row: UInt16(shellRow)
        ) else { return false }
        if config.embeddedBrowser {
            chrome.openBrowser(url: url, onVT: manager.activeIndex)
        } else {
            clearLinkHover()
            NSWorkspace.shared.open(url)
        }
        return true
    }

    private func shellViewportRow(fromFullRow fullRow: Int) -> Int? {
        guard let full = fullGridSize() else { return nil }
        if !isSearchOpen {
            guard fullRow >= 0, fullRow < Int(full.rows) else { return nil }
            return fullRow
        }
        if config.searchPosition == .top {
            if fullRow == 0 { return nil }
            return fullRow - 1
        }
        // Bottom HUD.
        if fullRow == Int(full.rows) - 1 { return nil }
        return fullRow
    }

    // MARK: - Embedded browser chrome (see BrowserChrome)

    @discardableResult
    func handleBrowserPageEditKeys(_ event: NSEvent) -> Bool {
        chrome.handleBrowserPageEditKeys(event)
    }

    @discardableResult
    func handleBrowserPageScrollKeys(_ event: NSEvent) -> Bool {
        chrome.handleBrowserPageScrollKeys(event)
    }

    @discardableResult
    func handleOpenBrowserChord(_ event: NSEvent) -> Bool {
        chrome.handleOpenBrowserChord(event)
    }

    @discardableResult
    func handleBrowserKeys(_ event: NSEvent) -> Bool {
        chrome.handleBrowserKeys(event)
    }

    /// Active WebView sits under stolen chrome rows (address + optional tab strip).
    ///
    /// AppKit frames use bottom-left origin: keep `origin.y` (content bottom) and
    /// shrink `height` so the top of the rect drops by chrome rows.
    /// Final frame is pixel-aligned so WebKit text is not rasterized on half-pixels.
    func layoutActiveBrowser() {
        guard let session = chrome.activeSession, let metrics else {
            chrome.hideAllBrowserViews()
            return
        }
        var r = contentRectPoints()
        let rows = CGFloat(session.stolenChromeRows)
        let steal = pad + metrics.cellHeight * rows
        r.size.height = max(0, r.size.height - steal)
        r.origin.x += pad
        r.size.width = max(0, r.size.width - 2 * pad)
        // Find HUD is the last full-grid row, not flush with the view bottom
        // (pad + leftover sit below it). Sit the WebView on that row's top.
        if session.findOpen, let full = fullGridSize(),
           let findRow = fullGridCellFrame(col: 0, row: Int(full.rows) - 1) {
            let top = r.maxY
            r.origin.y = findRow.maxY
            r.size.height = max(0, top - r.origin.y)
        }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        r = ContentLayout.pixelAlign(r, scale: scale)
        for (i, browser) in session.tabs.enumerated() {
            let visible = i == session.activeTabIndex
            browser.isHidden = !visible
            guard visible else { continue }
            let eps = 0.5 / scale
            if abs(browser.frame.origin.x - r.origin.x) > eps
                || abs(browser.frame.origin.y - r.origin.y) > eps
                || abs(browser.frame.size.width - r.size.width) > eps
                || abs(browser.frame.size.height - r.size.height) > eps {
                browser.frame = r
            }
            browser.autoresizingMask = session.findOpen ? [.width] : [.width, .height]
        }
    }

    // MARK: - Extension action chrome (after ← →, before URL)

    /// Frame of a full-grid cell in view coordinates (AppKit bottom-left origin).
    func fullGridCellFrame(col: Int, row: Int) -> CGRect? {
        guard let metrics, let full = fullGridSize(),
              col >= 0, row >= 0,
              col < Int(full.cols), row < Int(full.rows)
        else { return nil }
        let content = contentRectPoints()
        let x = content.minX + pad + CGFloat(col) * metrics.cellWidth
        // contentRect uses top-left-style minY (see fullGridCell); match that.
        let yFromTopTop = content.minY + pad + CGFloat(row) * metrics.cellHeight
        let y = bounds.height - (yFromTopTop + metrics.cellHeight)
        return CGRect(
            x: x,
            y: y,
            width: metrics.cellWidth,
            height: metrics.cellHeight
        )
    }

    func clearLinkHover() {
        if linkHover != nil {
            linkHover = nil
        }
        lastLinkHoverCell = nil
        NSCursor.arrow.set()
    }

    /// Ghostty: ⌘PageUp / ⌘PageDown smooth-scroll; accelerate on key-repeat.
    @discardableResult
    func handleScrollPage(_ event: NSEvent, manager: VtManager) -> Bool {
        guard let dir = KeyBridge.scrollPageDirection(from: event) else { return false }
        manager.active.scrollPageSmooth(direction: dir, isRepeat: event.isARepeat)
        return true
    }

    /// Ghostty macOS: ⌘A / ⌘K / ⌘Home / ⌘End / ⌘←→⌫.
    @discardableResult
    func handleTerminalChords(_ event: NSEvent, manager: VtManager) -> Bool {
        if let dir = KeyBridge.scrollExtremeDirection(from: event) {
            manager.active.scrollExtremeSmooth(direction: dir, isRepeat: event.isARepeat)
            return true
        }
        if KeyBridge.isSelectAll(event) {
            _ = manager.active.selectAll()
            return true
        }
        if KeyBridge.isClearScreen(event) {
            guard manager.active.clearScreen() else { return false }
            return true
        }
        if let bytes = KeyBridge.lineEditBytes(from: event) {
            manager.active.writeToPty(bytes)
            if manager.active.scrollToBottomKeystroke {
                manager.active.scrollViewportToBottom(isRepeat: event.isARepeat)
            }
            return true
        }
        return false
    }

    /// Ghostty macOS defaults: ⌘+/⌘= increase, ⌘- decrease (1pt), ⌘0 reset.
    @discardableResult
    func handleFontSizeKeys(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command),
              !flags.contains(.control),
              !flags.contains(.option)
        else { return false }

        let keyCode = event.keyCode
        // US: 24 = `=`, 27 = `-`, 29 = `0`; keypad: 69 = `+`, 78 = `-`, 82 = `0`.
        let chars = event.charactersIgnoringModifiers ?? ""
        let increase =
            keyCode == 24 || keyCode == 69
            || chars == "=" || chars == "+"
        let decrease =
            keyCode == 27 || keyCode == 78
            || chars == "-" || chars == "−"
        let reset =
            (keyCode == 29 || keyCode == 82 || chars == "0")
            && !flags.contains(.shift)

        if increase {
            adjustFontSize(by: 1)
            return true
        }
        if decrease {
            adjustFontSize(by: -1)
            return true
        }
        if reset {
            resetFontSize()
            return true
        }
        return false
    }

    /// Runtime font zoom (points). Clamped like Ghostty (1…255). Rebuilds metrics + VT size.
    private func adjustFontSize(by delta: CGFloat) {
        if originalFontSize == nil {
            originalFontSize = config.fontSize
        }
        let next = min(255, max(1, config.fontSize + delta))
        applyFontSize(next)
    }

    private func resetFontSize() {
        let base = originalFontSize ?? config.fontSize
        originalFontSize = base
        applyFontSize(base)
    }

    /// Page zoom matches runtime font zoom (`fontSize /` pre-zoom size).
    var pageZoomScale: CGFloat {
        let base = originalFontSize ?? config.fontSize
        guard base > 0.001 else { return 1 }
        return max(0.25, min(5, config.fontSize / base))
    }

    private func applyFontSize(_ points: CGFloat) {
        let next = min(255, max(1, points))
        guard abs(next - config.fontSize) > 0.001 else { return }
        config.fontSize = next
        refreshMetrics(force: true)
        applyResize()
        chrome.applyPageZoom(pageZoomScale)
        if activeBrowser != nil {
            layoutActiveBrowser()
        }
    }

    override func flagsChanged(with event: NSEvent) {
        requestFrame()
        // ⌘ up/down: subscribe to mouseMoved only while held; refresh hover.
        let cmd = event.modifierFlags.contains(.command)
        updateTrackingAreas()
        if cmd {
            updateLinkHover(with: event)
        } else {
            clearLinkHover()
        }
    }

    /// While ⌘ is held, underline the clickable URL under the cursor.
    private func updateLinkHover(with event: NSEvent) {
        if activeBrowser != nil {
            clearLinkHover()
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command),
              let manager,
              let cell = fullGridCell(at: event),
              let shellRow = shellViewportRow(fromFullRow: cell.row)
        else {
            clearLinkHover()
            return
        }
        // Skip full resolve while the pointer stays on the same cell.
        if let last = lastLinkHoverCell,
           last.col == cell.col, last.row == shellRow,
           linkHover != nil {
            NSCursor.pointingHand.set()
            return
        }
        lastLinkHoverCell = (cell.col, shellRow)
        guard let hit = manager.active.linkHitAtViewport(
            col: UInt16(cell.col),
            row: UInt16(shellRow)
        ) else {
            if linkHover != nil {
                linkHover = nil
                NSCursor.arrow.set()
            }
            return
        }
        let next = TerminalRenderer.LinkHoverRange(
            row: shellRow,
            startX: hit.startCol,
            endX: hit.endCol
        )
        if linkHover != next {
            linkHover = next
        }
        NSCursor.pointingHand.set()
    }

    /// Show centered quit panel; `completion(true)` quits.
    func presentQuitConfirm(completion: @escaping (Bool) -> Void) {
        if isQuitConfirmOpen {
            // Already waiting — drop the newer terminate request.
            completion(false)
            return
        }
        isQuitConfirmOpen = true
        quitConfirmCompletion = completion
        requestFrame()
    }

    /// Keys while quit panel is open. Returns true if consumed.
    @discardableResult
    func handleQuitConfirmKey(_ event: NSEvent) -> Bool {
        guard isQuitConfirmOpen, event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Ignore pure modifiers.
        if event.keyCode == 56 || event.keyCode == 60 || event.keyCode == 59
            || event.keyCode == 62 || event.keyCode == 58 || event.keyCode == 61
            || event.keyCode == 55 || event.keyCode == 54 {
            return true
        }
        // Second ⌘Q while open → confirm quit.
        if flags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "q" {
            resolveQuitConfirm(true)
            return true
        }
        switch event.keyCode {
        case 36, 76: // Return / keypad Enter
            resolveQuitConfirm(true)
            return true
        case 53: // Esc
            resolveQuitConfirm(false)
            return true
        default:
            break
        }
        let ch = event.charactersIgnoringModifiers?.lowercased()
        switch ch {
        case "y":
            resolveQuitConfirm(true)
            return true
        case "n":
            resolveQuitConfirm(false)
            return true
        default:
            // Swallow everything else so the PTY does not see it.
            return true
        }
    }

    private func resolveQuitConfirm(_ confirmed: Bool) {
        guard isQuitConfirmOpen else { return }
        isQuitConfirmOpen = false
        let done = quitConfirmCompletion
        quitConfirmCompletion = nil
        // Drop packed GPU instances so the next frame cannot re-present the panel.
        renderer?.invalidatePackedInstances()
        done?(confirmed)
    }

    /// Claim host chords before the menu. Leftover ⌘ goes to `super` (terminal) or
    /// is declined (browser) so WebKit can still see Edit equivalents.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }
        switch routeKey(event) {
        case .consumed, .toPty:
            return true
        case .toWebView:
            return false
        case .toMenu:
            return super.performKeyEquivalent(with: event)
        }
    }

    // MARK: - Scrollback search (⌘F, stolen bottom VT row)

    @discardableResult
    func handleSearchKeys(_ event: NSEvent) -> Bool {
        search.handleKeys(event)
    }

    @discardableResult
    func handleSearchTyping(_ event: NSEvent) -> Bool {
        search.handleTyping(event)
    }

    func openSearch() {
        search.open()
    }

    func closeSearch() {
        search.close()
    }

    @objc override func selectAll(_ sender: Any?) {
        _ = manager?.active.selectAll()
        requestFrame()
    }

    @objc func copy(_ sender: Any?) {
        _ = manager?.active.copySelectionToPasteboard()
    }

    @objc func paste(_ sender: Any?) {
        guard let manager, let text = Clipboard.pasteString() else { return }
        manager.active.pasteText(text)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(selectAll(_:)) {
            return manager?.active.isLive == true
        }
        if menuItem.action == #selector(copy(_:)) {
            return manager?.active.selectionActive == true
        }
        if menuItem.action == #selector(paste(_:)) {
            return Clipboard.pasteString() != nil
        }
        return true
    }
}
