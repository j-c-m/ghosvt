import AppKit
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
        preferredFramesPerSecond = 60
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
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        refreshMetrics(force: true)
        spawnIfNeeded()
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
        let scale = window?.backingScaleFactor ?? 2
        let content = contentRectPoints()
        let cols = max(1, Int((content.width - 2 * pad) / metrics.cellWidth))
        let rows = max(1, Int((content.height - 2 * pad) / metrics.cellHeight))
        return (
            UInt16(cols),
            UInt16(rows),
            UInt32(max(1, (metrics.cellWidth * scale).rounded())),
            UInt32(max(1, (metrics.cellHeight * scale).rounded()))
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
        let contentPx = ContentLayout.contentRect(in: drawableSize, maxAspect: config.maxAspect)
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
            visualOffsetRows: visualOffset
        )
    }

    // MARK: - Input

    override func scrollWheel(with event: NSEvent) {
        guard let manager, let metrics else {
            super.scrollWheel(with: event)
            return
        }
        let session = manager.active
        guard session.isLive else { return }

        // Apps with mouse tracking (e.g. full-screen TUI) own the wheel.
        if session.isMouseTracking() {
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

    /// Host selection when not in mouse-tracking mode, or always with Shift.
    private func shouldHostSelect(_ event: NSEvent) -> Bool {
        guard let manager else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.shift) { return true }
        return !manager.active.isMouseTracking()
    }

    override func mouseDown(with event: NSEvent) {
        guard let manager, event.buttonNumber == 0 else {
            super.mouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        guard shouldHostSelect(event), let hit = makeSelectionHit(event) else {
            selecting = false
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        selectRectangle = flags.contains(.option)
        selecting = true
        let timeNs = UInt64(event.timestamp * 1_000_000_000)
        manager.active.selectionPress(hit: hit, timeNs: timeNs, rectangle: selectRectangle)
    }

    override func mouseDragged(with event: NSEvent) {
        guard selecting, let manager, let hit = makeSelectionHit(event) else {
            super.mouseDragged(with: event)
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        selectRectangle = flags.contains(.option)
        _ = manager.active.selectionDrag(hit: hit, rectangle: selectRectangle)
    }

    override func mouseUp(with event: NSEvent) {
        guard selecting, let manager else {
            super.mouseUp(with: event)
            return
        }
        selecting = false
        manager.active.selectionRelease(hit: makeSelectionHit(event))
        if config.copyOnSelect {
            _ = manager.active.copySelectionToPasteboard()
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        // Middle-click paste (button 2).
        guard event.buttonNumber == 2, let manager else {
            super.otherMouseDown(with: event)
            return
        }
        if let text = Clipboard.pasteString() {
            manager.active.pasteText(text)
        }
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
