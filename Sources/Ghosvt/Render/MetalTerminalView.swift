import AppKit
import CGhosttyVT
import Metal
import MetalKit
import QuartzCore

final class MetalTerminalView: MTKView, NSMenuItemValidation {
    var manager: VtManager?
    var config: Config = Config()

    private var metrics: CellMetrics?
    private var renderer: TerminalRenderer?

    private let pad: CGFloat = 4
    private var lastCols: UInt16 = 0
    private var lastRows: UInt16 = 0
    private var lastCellW: UInt32 = 0
    private var lastCellH: UInt32 = 0
    private var lastScale: CGFloat = 0
    private var lastFontSize: CGFloat = 0
    private var lastFrameTime: CFTimeInterval = 0
    private var scrollConfigApplied = false
    private var selecting = false
    private var selectRectangle = false
    /// Any mouse button currently held (for letterbox freeze during app selection).
    private var mouseButtonsHeld: Set<Int> = []
    private var trackingArea: NSTrackingArea?
    private var focusObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    /// Last logged display range (minInterval, maxInterval, maxFps); skip repeat logs.
    private var lastLoggedDisplay: (minI: CFTimeInterval, maxI: CFTimeInterval, fps: Int)?

    // Scrollback search (⌘F): per-VT state; steals one row while that VT is active.
    private struct VTSearchState {
        var isOpen = false
        var needle = ""
        var matches: [TerminalSession.SearchMatch] = []
        var index = 0
    }
    private var searchByVT: [VTSearchState] = []
    private var searchDebounce: DispatchWorkItem?

    /// Whether the *active* VT has the search HUD open.
    private(set) var isSearchOpen: Bool {
        get { activeSearchState?.isOpen ?? false }
        set {
            ensureSearchSlots()
            guard let i = manager?.activeIndex, i < searchByVT.count else { return }
            searchByVT[i].isOpen = newValue
        }
    }

    private var searchNeedle: String {
        get { activeSearchState?.needle ?? "" }
        set {
            ensureSearchSlots()
            guard let i = manager?.activeIndex, i < searchByVT.count else { return }
            searchByVT[i].needle = newValue
        }
    }

    private var searchMatches: [TerminalSession.SearchMatch] {
        get { activeSearchState?.matches ?? [] }
        set {
            ensureSearchSlots()
            guard let i = manager?.activeIndex, i < searchByVT.count else { return }
            searchByVT[i].matches = newValue
        }
    }

    private var searchIndex: Int {
        get { activeSearchState?.index ?? 0 }
        set {
            ensureSearchSlots()
            guard let i = manager?.activeIndex, i < searchByVT.count else { return }
            searchByVT[i].index = newValue
        }
    }

    private var activeSearchState: VTSearchState? {
        guard let i = manager?.activeIndex, i < searchByVT.count else { return nil }
        return searchByVT[i]
    }

    private func ensureSearchSlots() {
        let n = manager?.config.vtCount ?? manager?.sessions.count ?? 0
        guard n > 0 else { return }
        if searchByVT.count < n {
            searchByVT.append(contentsOf: repeatElement(VTSearchState(), count: n - searchByVT.count))
        }
    }

    override init(frame frameRect: CGRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device)
        commonInit()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        guard let device else { return }
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        isPaused = false
        enableSetNeedsDisplay = false
        autoResizeDrawable = true
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
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeFocusObservers()
        removeWorkspaceObservers()
        window?.makeFirstResponder(self)
        rebindDisplay()
        spawnIfNeeded()
        updateTrackingAreas()
        if window != nil {
            installFocusObservers()
            installWorkspaceObservers()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let opts: NSTrackingArea.Options = [
            .activeInKeyWindow,
            .mouseMoved,
            .inVisibleRect,
            .enabledDuringMouseDrag,
        ]
        let area = NSTrackingArea(rect: bounds, options: opts, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    private func removeFocusObservers() {
        for o in focusObservers {
            NotificationCenter.default.removeObserver(o)
        }
        focusObservers.removeAll()
    }

    private func removeWorkspaceObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        for o in workspaceObservers {
            nc.removeObserver(o)
        }
        workspaceObservers.removeAll()
    }

    private func installFocusObservers() {
        removeFocusObservers()
        guard let window else { return }
        let nc = NotificationCenter.default
        // Capture manager weakly via view; notifications are main-queue.
        focusObservers.append(nc.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.manager?.active.encodeFocus(gained: true)
            }
        })
        focusObservers.append(nc.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.manager?.active.encodeFocus(gained: false)
            }
        })
        // Fullscreen move / drag to another display: scale, grid, VRR.
        focusObservers.append(nc.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.rebindDisplay()
            }
        })
    }

    private func installWorkspaceObservers() {
        removeWorkspaceObservers()
        let nc = NSWorkspace.shared.notificationCenter
        // Pause only when displays actually sleep — not willSleep (can cancel).
        workspaceObservers.append(nc.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isPaused = true
            }
        })
        // Both wake paths may fire; resumeAfterSleep gates on isPaused.
        workspaceObservers.append(nc.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.resumeAfterSleep()
            }
        })
        workspaceObservers.append(nc.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.resumeAfterSleep()
            }
        })
    }

    /// Adaptive-Sync + HiDPI metrics + resize all live VTs (SIGWINCH).
    private func rebindDisplay() {
        applyDisplayRefreshRate()
        refreshMetrics(force: true)
        applyResize()
    }

    /// Idempotent: second wake notification is a no-op if already resumed.
    private func resumeAfterSleep() {
        guard isPaused else { return }
        isPaused = false
        rebindDisplay()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        refreshMetrics(force: false)
        spawnIfNeeded()
        applyResize()
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
    private func contentRectPoints() -> CGRect {
        ContentLayout.contentRect(in: bounds.size, maxAspect: config.maxAspect)
    }

    /// Full cell grid that fits the content rect (includes the search row when open).
    private func fullGridSize() -> (cols: UInt16, rows: UInt16, cellW: UInt32, cellH: UInt32)? {
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
    private func applyResize() {
        guard let manager, let full = fullGridSize() else { return }
        ensureSearchSlots()
        let fullRows = full.rows
        for (i, session) in manager.sessions.enumerated() where session.isLive {
            let open = i < searchByVT.count && searchByVT[i].isOpen
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
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let renderer,
              let drawable = currentDrawable,
              let rpd = currentRenderPassDescriptor,
              let manager,
              let metrics
        else { return }

        if !scrollConfigApplied {
            for s in manager.sessions {
                s.applyScrollConfig(config)
            }
            scrollConfigApplied = true
        }

        manager.pollAllIO()

        let now = CACurrentMediaTime()
        let dt = lastFrameTime > 0 ? now - lastFrameTime : 1.0 / 60.0
        lastFrameTime = now

        // Step scroll physics for every live VT so inactive ones settle too.
        for s in manager.sessions where s.isLive {
            s.stepScroll(dt: dt)
        }

        let indicator = manager.tickIndicator()
        let scale = window?.backingScaleFactor ?? 2
        // Content rect in drawable pixels (same aspect cap as grid sizing).
        // Snap in drawable pixels so the cell grid lands on whole framebuffer pixels.
        let contentPx = ContentLayout.contentRect(
            in: drawableSize,
            maxAspect: config.maxAspect,
            snapPixels: true
        )
        let visualOffset = manager.active.visualOffsetRows()

        let searchHL = viewportSearchHighlights(session: manager.active)
        let hudLayout = isSearchOpen ? searchHUDLayout(cols: Int(lastCols)) : nil
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
            freezeLetterbox: !mouseButtonsHeld.isEmpty || selecting
        )
        syncLetterboxChrome(from: renderer)
    }

    /// Stolen-row layout: `/needle` left; count + ↑ ↓ right (Ghostty chevron order).
    private struct SearchHUDLayout {
        var line: String
        var caretCol: Int
        /// Column of ↑ (next / older).
        var upCol: Int
        /// Column of ↓ (previous / newer).
        var downCol: Int
    }

    private func searchHUDLayout(cols: Int) -> SearchHUDLayout {
        guard cols > 0 else {
            return SearchHUDLayout(line: "/", caretCol: 1, upCol: -1, downCol: -1)
        }
        let status: String
        if searchNeedle.isEmpty {
            status = ""
        } else if searchMatches.isEmpty {
            status = "-/0"
        } else {
            status = "\(searchIndex + 1)/\(searchMatches.count)"
        }
        // Trailing chrome: optional status, then ↑ space ↓ (Ghostty up=next).
        let nav = "↑ ↓"
        let right = status.isEmpty ? (" " + nav) : (" " + status + " " + nav)
        let rightCols = terminalCellCols(right)

        // Prefer keeping right chrome; fit `/` + needle into the rest.
        let leftBudget = max(1, cols - rightCols)
        let slash = "/"
        let slashCols = terminalCellCols(slash)
        let needleBudget = max(0, leftBudget - slashCols)
        let needle = prefixFittingCellCols(searchNeedle, maxCols: needleBudget)
        let left = slash + needle
        let leftCols = terminalCellCols(left)
        let caretCol = min(leftCols, cols - 1)

        // Cell slots (one glyph start or spacer per column) so wide chars don't
        // desync caret / ↑↓ hit targets.
        var cells = Array(repeating: " ", count: cols)
        placeCellString(left, at: 0, into: &cells)
        let rightStart = max(0, cols - rightCols)
        placeCellString(right, at: rightStart, into: &cells)
        let line = cells.joined()

        // Line ends with "↑ ↓" (three cells) → up at cols-3, down at cols-1.
        let upCol = cols >= 3 ? cols - 3 : -1
        let downCol = cols >= 1 ? cols - 1 : -1
        return SearchHUDLayout(line: line, caretCol: caretCol, upCol: upCol, downCol: downCol)
    }

    /// Terminal grid columns for `s` (Ghostty width table; 0/1/2 per codepoint).
    private func terminalCellCols(_ s: String) -> Int {
        var n = 0
        for scalar in s.unicodeScalars {
            n += Int(ghostty_unicode_codepoint_width(scalar.value))
        }
        return n
    }

    /// Longest prefix of `s` whose display width is ≤ `maxCols`.
    private func prefixFittingCellCols(_ s: String, maxCols: Int) -> String {
        guard maxCols > 0 else { return "" }
        var used = 0
        var out = ""
        for ch in s {
            let w = terminalCellCols(String(ch))
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

    /// Write `s` into `cells` starting at column `start` (wide glyphs leave blank spacer cells).
    private func placeCellString(_ s: String, at start: Int, into cells: inout [String]) {
        var col = start
        for ch in s {
            let w = terminalCellCols(String(ch))
            if w == 0 {
                // Combining mark: attach to previous cell text if possible.
                if col > start, col - 1 < cells.count {
                    cells[col - 1].append(ch)
                }
                continue
            }
            if col >= cells.count { break }
            cells[col] = String(ch)
            // Trailing cells of a wide glyph stay spaces (bg only, no second glyph).
            for k in 1..<w where col + k < cells.count {
                cells[col + k] = " "
            }
            col += w
        }
    }

    /// Map a view click to a cell in the full content grid (includes stolen search row).
    private func fullGridCell(at event: NSEvent) -> (col: Int, row: Int)? {
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

    /// Click ↑ / ↓ on the stolen search row.
    @discardableResult
    private func handleSearchRowClick(_ event: NSEvent) -> Bool {
        guard isSearchOpen else { return false }
        guard let cell = fullGridCell(at: event),
              let full = fullGridSize()
        else { return false }
        // Stolen row: top of full grid, or last row when bottom.
        let searchRow = config.searchPosition == .top ? 0 : Int(full.rows) - 1
        guard cell.row == searchRow else { return false }
        let layout = searchHUDLayout(cols: Int(full.cols))
        if cell.col == layout.upCol {
            navigateSearch(reverse: false)
            return true
        }
        if cell.col == layout.downCol {
            navigateSearch(reverse: true)
            return true
        }
        // Click elsewhere on the search row: keep focus, do not start selection.
        return true
    }

    /// Map screen-coordinate matches into the current viewport for paint.
    private func viewportSearchHighlights(
        session: TerminalSession
    ) -> [TerminalRenderer.SearchHighlightRange] {
        guard isSearchOpen, !searchMatches.isEmpty else { return [] }
        guard let snap = session.queryScrollbar() else { return [] }
        let offset = Int(snap.offset)
        let vpRows = Int(snap.len)
        guard vpRows > 0 else { return [] }
        var out: [TerminalRenderer.SearchHighlightRange] = []
        out.reserveCapacity(min(searchMatches.count, 64))
        for (i, m) in searchMatches.enumerated() {
            let row = Int(m.screenY) - offset
            guard row >= 0, row < vpRows else { continue }
            out.append(TerminalRenderer.SearchHighlightRange(
                row: row,
                startX: Int(m.startX),
                endX: Int(m.endX),
                isCurrent: i == searchIndex
            ))
        }
        return out
    }

    /// Keep MTKView clear + window chrome in lockstep with terminal / FS TUI background.
    private func syncLetterboxChrome(from renderer: TerminalRenderer) {
        let bg = renderer.lastLetterboxBg
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
        noteMouseDown(event)
        if event.buttonNumber == 0, handleSearchRowClick(event) {
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
        noteMouseUp(event)
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
        if let manager, manager.active.isMouseTracking(), !selecting {
            sendAppMouse(event, action: GHOSTTY_MOUSE_ACTION_MOTION, button: nil)
            return
        }
        super.mouseMoved(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        noteMouseDown(event)
        if let manager, manager.active.isMouseTracking(), !shouldHostSelect(event) {
            sendAppMouse(event, action: GHOSTTY_MOUSE_ACTION_PRESS, button: GHOSTTY_MOUSE_BUTTON_RIGHT)
            return
        }
        super.rightMouseDown(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        noteMouseUp(event)
        if let manager, manager.active.isMouseTracking() {
            sendAppMouse(event, action: GHOSTTY_MOUSE_ACTION_RELEASE, button: GHOSTTY_MOUSE_BUTTON_RIGHT)
            return
        }
        super.rightMouseUp(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
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
        noteMouseDown(event)
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
        noteMouseUp(event)
        if event.buttonNumber == 2, let manager, manager.active.isMouseTracking() {
            sendAppMouse(event, action: GHOSTTY_MOUSE_ACTION_RELEASE, button: GHOSTTY_MOUSE_BUTTON_MIDDLE)
            return
        }
        super.otherMouseUp(with: event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        if event.buttonNumber == 2, let manager, manager.active.isMouseTracking() {
            sendAppMouse(event, action: GHOSTTY_MOUSE_ACTION_MOTION, button: GHOSTTY_MOUSE_BUTTON_MIDDLE)
            return
        }
        super.otherMouseDragged(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard let manager else {
            super.keyDown(with: event)
            return
        }
        if handleSearchKeys(event) {
            return
        }
        if isSearchOpen, handleSearchTyping(event) {
            return
        }
        if handleVtSwitch(event, manager: manager) {
            return
        }
        if handleScrollPage(event, manager: manager) {
            return
        }
        // Do not feed Command chords into the PTY (except we already handled VT switch).
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            return
        }
        // Typing clears the active selection (macOS terminal convention).
        if manager.active.selectionActive {
            manager.active.clearSelection()
        }
        KeyBridge.handleKeyDown(event, session: manager.active)
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

    /// Activate the new VT; restore that VT’s search HUD if it was open.
    private func afterVtSwitch(manager: VtManager) {
        searchDebounce?.cancel()
        searchDebounce = nil
        ensureSearchSlots()
        // Per-VT open flag drives shell size for every session.
        applyResize()
        if let g = shellGridSize() {
            manager.ensureActiveStarted(
                cols: g.cols, rows: g.rows,
                cellWidthPx: g.cellW, cellHeightPx: g.cellH
            )
        }
        // Refresh matches against this session’s scrollback (coords can drift).
        if isSearchOpen, !searchNeedle.isEmpty {
            runSearch(needle: searchNeedle, selectFirst: false)
        }
        window?.makeFirstResponder(self)
    }

    /// Ghostty: ⌘PageUp / ⌘PageDown smooth-scroll; accelerate on key-repeat.
    @discardableResult
    func handleScrollPage(_ event: NSEvent, manager: VtManager) -> Bool {
        guard let dir = KeyBridge.scrollPageDirection(from: event) else { return false }
        manager.active.scrollPageSmooth(direction: dir, isRepeat: event.isARepeat)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        // Keep first responder; do not let the event bubble into beeps.
    }

    /// Claim ⌘1… / ⌘F1… / ⌘C / ⌘V / ⌘F before the menu; leave ⌘Q to the system.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            if event.charactersIgnoringModifiers?.lowercased() == "q" {
                NSApp.terminate(nil)
                return true
            }
            if handleSearchKeys(event) {
                return true
            }
            if let manager, handleVtSwitch(event, manager: manager) {
                return true
            }
            if let manager, handleScrollPage(event, manager: manager) {
                return true
            }
            // Copy / paste (ignore other modifiers like Shift for basic chords).
            if !flags.contains(.control), !flags.contains(.option) {
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "c":
                    if let manager, manager.active.copySelectionToPasteboard() {
                        return true
                    }
                    // No selection: do not swallow (allow system beep / no-op).
                    return true
                case "v":
                    if let manager, let text = Clipboard.pasteString() {
                        manager.active.pasteText(text)
                    }
                    return true
                default:
                    break
                }
            }
        }
        if !flags.contains(.command) {
            keyDown(with: event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: - Scrollback search (⌘F, stolen bottom VT row)

    /// Handle ⌘F / ⌘G / Esc-when-search-open. Returns true if consumed.
    @discardableResult
    func handleSearchKeys(_ event: NSEvent) -> Bool {
        if KeyBridge.isSearchToggle(event) {
            if isSearchOpen {
                closeSearch()
            } else {
                openSearch()
            }
            return true
        }
        if let forward = KeyBridge.searchNavigateForward(from: event) {
            if isSearchOpen {
                navigateSearch(reverse: !forward)
                return true
            }
            return false
        }
        if isSearchOpen, event.keyCode == 53 { // Escape
            closeSearch()
            return true
        }
        return false
    }

    /// Typing into the stolen search row (not the PTY).
    @discardableResult
    func handleSearchTyping(_ event: NSEvent) -> Bool {
        guard isSearchOpen else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.control) {
            return false
        }

        switch event.keyCode {
        case 36, 76: // Return / keypad Enter
            if searchMatches.isEmpty, !searchNeedle.isEmpty {
                runSearch(needle: searchNeedle, selectFirst: true)
            } else {
                navigateSearch(reverse: flags.contains(.shift))
            }
            return true
        case 51: // Delete (backspace)
            if !searchNeedle.isEmpty {
                searchNeedle.removeLast()
                scheduleSearch()
            }
            return true
        case 117: // Forward delete — clear last grapheme cluster end; same as backspace for MVP
            if !searchNeedle.isEmpty {
                searchNeedle.removeLast()
                scheduleSearch()
            }
            return true
        case 126: // Up → next (older), Ghostty chevron.up
            navigateSearch(reverse: false)
            return true
        case 125: // Down → previous (newer)
            navigateSearch(reverse: true)
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
                    searchNeedle.append(ch)
                    changed = true
                }
            }
            if changed {
                scheduleSearch()
                return true
            }
        }
        // Swallow other non-command keys so they never reach the shell.
        return true
    }

    func openSearch() {
        ensureSearchSlots()
        if isSearchOpen { return }
        isSearchOpen = true
        applyResize()
        window?.makeFirstResponder(self)
        if !searchNeedle.isEmpty {
            runSearch(needle: searchNeedle, selectFirst: true)
        } else {
            searchMatches = []
            searchIndex = 0
        }
    }

    func closeSearch() {
        ensureSearchSlots()
        guard isSearchOpen else { return }
        searchDebounce?.cancel()
        searchDebounce = nil
        isSearchOpen = false
        searchMatches = []
        searchIndex = 0
        // Keep needle on this VT so reopening restores the last query.
        manager?.active.clearSelection()
        applyResize()
        window?.makeFirstResponder(self)
    }

    private func scheduleSearch() {
        searchDebounce?.cancel()
        let needle = searchNeedle
        let work = DispatchWorkItem { [weak self] in
            self?.runSearch(needle: needle, selectFirst: true)
        }
        searchDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    private func runSearch(needle: String, selectFirst: Bool) {
        searchNeedle = needle
        guard let session = manager?.active else {
            searchMatches = []
            searchIndex = 0
            return
        }
        if needle.isEmpty {
            searchMatches = []
            searchIndex = 0
            session.clearSelection()
            return
        }
        let matches = session.findMatches(needle: needle)
        searchMatches = matches
        if matches.isEmpty {
            searchIndex = 0
            session.clearSelection()
            return
        }
        // Matches are newest-first (index 0 = bottom of scrollback). Start there.
        if selectFirst {
            searchIndex = 0
        } else {
            searchIndex = min(searchIndex, matches.count - 1)
        }
        applyCurrentMatch()
    }

    private func navigateSearch(reverse: Bool) {
        guard !searchMatches.isEmpty else {
            if !searchNeedle.isEmpty {
                runSearch(needle: searchNeedle, selectFirst: true)
            }
            return
        }
        // Ghostty: next = older (up / higher index), prev = newer (down / lower index).
        if reverse {
            searchIndex = (searchIndex - 1 + searchMatches.count) % searchMatches.count
        } else {
            searchIndex = (searchIndex + 1) % searchMatches.count
        }
        applyCurrentMatch()
    }

    private func applyCurrentMatch() {
        guard let session = manager?.active,
              searchMatches.indices.contains(searchIndex)
        else { return }
        let match = searchMatches[searchIndex]
        // Highlight all matches in paint (gold / peach). Do not install VT selection.
        session.clearSelection()
        session.scrollToSearchMatch(match)
    }

    @objc func copy(_ sender: Any?) {
        _ = manager?.active.copySelectionToPasteboard()
    }

    @objc func paste(_ sender: Any?) {
        guard let manager, let text = Clipboard.pasteString() else { return }
        manager.active.pasteText(text)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copy(_:)) {
            return manager?.active.selectionActive == true
        }
        if menuItem.action == #selector(paste(_:)) {
            return Clipboard.pasteString() != nil
        }
        return true
    }
}
