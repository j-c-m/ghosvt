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
    private var lastScale: CGFloat = 0
    private var lastFontSize: CGFloat = 0
    private var lastFrameTime: CFTimeInterval = 0
    private var scrollConfigApplied = false
    private var selecting = false
    private var selectRectangle = false
    private var trackingArea: NSTrackingArea?
    private var focusObservers: [NSObjectProtocol] = []
    /// Last logged display range (minInterval, maxInterval, maxFps); skip repeat logs.
    private var lastLoggedDisplay: (minI: CFTimeInterval, maxI: CFTimeInterval, fps: Int)?

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
        window?.makeFirstResponder(self)
        applyDisplayRefreshRate()
        refreshMetrics(force: true)
        spawnIfNeeded()
        updateTrackingAreas()
        if window != nil {
            installFocusObservers()
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
        focusObservers.append(nc.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyDisplayRefreshRate()
            }
        })
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

    private func gridSize() -> (cols: UInt16, rows: UInt16, cellW: UInt32, cellH: UInt32)? {
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

    private func spawnIfNeeded() {
        guard let manager, let g = gridSize() else { return }
        manager.ensureActiveStarted(cols: g.cols, rows: g.rows, cellWidthPx: g.cellW, cellHeightPx: g.cellH)
        lastCols = g.cols
        lastRows = g.rows
    }

    private func applyResize() {
        guard let manager, let g = gridSize() else { return }
        if g.cols != lastCols || g.rows != lastRows {
            manager.resizeAll(cols: g.cols, rows: g.rows, cellWidthPx: g.cellW, cellHeightPx: g.cellH)
            lastCols = g.cols
            lastRows = g.rows
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
            fontLigatures: config.fontLigatures
        )
        syncLetterboxChrome(from: renderer)
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
        return manager.active.selectionHit(
            viewPoint: convert(event.locationInWindow, from: nil),
            viewSize: bounds.size,
            contentRectPoints: contentRectPoints(),
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
        let content = contentRectPoints()
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
            padTop: UInt32(max(0, (pad * scale).rounded()))
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
        if let manager, manager.active.isMouseTracking(), !shouldHostSelect(event) {
            sendAppMouse(event, action: GHOSTTY_MOUSE_ACTION_PRESS, button: GHOSTTY_MOUSE_BUTTON_RIGHT)
            return
        }
        super.rightMouseDown(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
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

    override func otherMouseDown(with event: NSEvent) {
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
        if handleVtSwitch(event, manager: manager) {
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
            if let g = gridSize() {
                manager.ensureActiveStarted(cols: g.cols, rows: g.rows, cellWidthPx: g.cellW, cellHeightPx: g.cellH)
            }
            return true
        }
        if let delta = KeyBridge.vtSwitchDelta(from: event) {
            manager.switchByDelta(delta)
            if let g = gridSize() {
                manager.ensureActiveStarted(cols: g.cols, rows: g.rows, cellWidthPx: g.cellW, cellHeightPx: g.cellH)
            }
            return true
        }
        return false
    }

    override func flagsChanged(with event: NSEvent) {
        // Keep first responder; do not let the event bubble into beeps.
    }

    /// Claim ⌘1… / ⌘F1… / ⌘C / ⌘V before the menu; leave ⌘Q to the system.
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
            if let manager, handleVtSwitch(event, manager: manager) {
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
