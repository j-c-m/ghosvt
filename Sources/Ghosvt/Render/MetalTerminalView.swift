import AppKit
import Metal
import MetalKit
import QuartzCore

final class MetalTerminalView: MTKView {
    var manager: VtManager?
    var config: Config = Config()

    private var metrics: CellMetrics?
    private var renderer: TerminalRenderer?

    private let pad: CGFloat = 4
    private var lastCols: UInt16 = 0
    private var lastRows: UInt16 = 0
    private var lastScale: CGFloat = 0
    private var lastFontSize: CGFloat = 0

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
        clearColor = MTLClearColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1)

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

        manager.pollAllIO()
        let indicator = manager.tickIndicator()
        let scale = window?.backingScaleFactor ?? 2
        // Content rect in drawable pixels (same aspect cap as grid sizing).
        let contentPx = ContentLayout.contentRect(in: drawableSize, maxAspect: config.maxAspect)

        renderer.draw(
            session: manager.active,
            metrics: metrics,
            drawable: drawable,
            renderPassDescriptor: rpd,
            drawableSize: drawableSize,
            contentRect: contentPx,
            scale: scale,
            indicator: indicator,
            clearColor: clearColor
        )
    }

    // MARK: - Input

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

    /// Claim ⌘1… / ⌘F1… before the menu; leave ⌘Q to the system.
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
        }
        if !flags.contains(.command) {
            keyDown(with: event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
