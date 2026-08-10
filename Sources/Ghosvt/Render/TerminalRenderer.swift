import CGhosttyVT
import CoreText
import Foundation
import Metal
import MetalKit
import QuartzCore

/// Metal terminal painter: dirty-aware grid cache + glyph atlas instances.
final class TerminalRenderer {
    let device: MTLDevice
    let queue: MTLCommandQueue
    var pipeline: MTLRenderPipelineState
    var sampler: MTLSamplerState
    var atlas: GlyphAtlas
    var shaper = ShaperCache()
    var instanceBuffer: MTLBuffer?
    var uniformBuffer: MTLBuffer?
    var instanceCapacity = 0
    var floatScratch = [Float]()
    var fontLigatures = true

    let padPoints: CGFloat

    // MARK: Grid cache
    var gridCells: [CellInstance] = []
    /// Viewport cell content for cursor under-glyph (no second VT walk).
    var rowCellCache: [TerminalRowCell] = []
    var underlineExtras: [CellInstance] = []
    /// Multi-cell ligature / per-cell ink drawn after backgrounds.
    var glyphExtras: [CellInstance] = []
    var gridCols = 0
    var gridRows = 0
    var lastDrawnCount = 0
    var lastLayoutKey: LayoutKey?
    var lastDefBg = (r: DefaultColors.background.r, g: DefaultColors.background.g, b: DefaultColors.background.b)
    /// Color used to clear the full drawable (letterbox bars match terminal / FS TUI).
    private(set) var lastLetterboxBg = DefaultColors.background
    var lastIndicator: String?
    var lastBlinkOn = true
    var lastVisualY: Float = 0
    var lastCursorX: Int = -1
    var lastCursorY: Int = -1
    var lastCursorVisible: Bool = false
    var blinkPeriod: CFTimeInterval = 0.53
    var prewarmedKey: String?

    /// Viewport-local search match ranges for this frame (row 0 = top of viewport).
    struct SearchHighlightRange: Equatable {
        var row: Int
        var startX: Int
        var endX: Int
        var isCurrent: Bool
    }
    var searchHighlights: [SearchHighlightRange] = []
    private var lastSearchHighlights: [SearchHighlightRange] = []
    /// Stolen-row search HUD line (nil when search closed).
    private var lastSearchHUD: String?

    // MARK: Display pacing (Adaptive-Sync / fixed refresh)
    /// Shortest frame hold (1 / max Hz).
    var displayMinInterval: CFTimeInterval = 1.0 / 60.0
    /// Longest frame hold (1 / min Hz). Equal to min on fixed-rate panels.
    var displayMaxInterval: CFTimeInterval = 1.0 / 60.0
    /// True when the screen reports a refresh range (ProMotion / Adaptive-Sync).
    var adaptiveSync = false
    /// EMA of GPU command-buffer time for content-paced presents (WWDC21).
    let gpuTimeEMA = GPUTimeEMA(1.0 / 60.0)

    /// Mutable Double shared with MTL completed handlers (pacing only).
    final class GPUTimeEMA: @unchecked Sendable {
        var value: CFTimeInterval
        init(_ value: CFTimeInterval) { self.value = value }
    }

    struct LayoutKey: Equatable {
        var originX: Float
        var originY: Float
        var cellW: Float
        var cellH: Float
        var padPx: Float
        var cols: Int
        var rows: Int
        var fontPx: Int
    }

    init?(device: MTLDevice, pixelFormat: MTLPixelFormat, padPoints: CGFloat = 4) {
        self.device = device
        self.padPoints = padPoints
        guard let queue = device.makeCommandQueue() else { return nil }
        self.queue = queue

        guard let atlas = GlyphAtlas(device: device) else { return nil }
        self.atlas = atlas

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        } catch {
            fputs("ghosvt: shader compile failed: \(error)\n", stderr)
            return nil
        }
        guard let vfn = library.makeFunction(name: "cell_vertex"),
              let ffn = library.makeFunction(name: "cell_fragment")
        else { return nil }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0].pixelFormat = pixelFormat
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        desc.colorAttachments[0].sourceAlphaBlendFactor = .one
        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        do {
            self.pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            fputs("ghosvt: pipeline failed: \(error)\n", stderr)
            return nil
        }

        let samp = MTLSamplerDescriptor()
        samp.minFilter = .nearest
        samp.magFilter = .nearest
        samp.sAddressMode = .clampToEdge
        samp.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samp) else { return nil }
        self.sampler = sampler
        self.uniformBuffer = device.makeBuffer(length: FrameUniforms.stride, options: .storageModeShared)
    }

    func resetAtlas() {
        atlas.clear()
        shaper.clear()
        prewarmedKey = nil
        lastLayoutKey = nil
        gridCells.removeAll(keepingCapacity: true)
        rowCellCache.removeAll(keepingCapacity: true)
        glyphExtras.removeAll(keepingCapacity: true)
        underlineExtras.removeAll(keepingCapacity: true)
        gridCols = 0
        gridRows = 0
    }

    /// Apply the screen’s refresh interval range for Adaptive-Sync pacing.
    func configureDisplay(minInterval: CFTimeInterval, maxInterval: CFTimeInterval) {
        let lo = max(minInterval, 1.0 / 1000.0)
        let hi = max(maxInterval, lo)
        displayMinInterval = lo
        displayMaxInterval = hi
        adaptiveSync = hi > lo * 1.01
        // Seed EMA at the fastest supported interval so the first active frames
        // do not under-pace on a cold start.
        gpuTimeEMA.value = lo
    }

    func draw(
        session: TerminalSession,
        metrics: CellMetrics,
        drawable: CAMetalDrawable,
        renderPassDescriptor: MTLRenderPassDescriptor,
        drawableSize: CGSize,
        contentRect: CGRect,
        scale: CGFloat,
        indicator: String?,
        clearColor: MTLClearColor,
        visualOffsetRows: Double = 0,
        fontLigatures: Bool = true,
        searchHighlights: [SearchHighlightRange] = [],
        searchHUD: String? = nil,
        searchCaretCol: Int = 0,
        searchHUDAtTop: Bool = false
    ) {
        self.fontLigatures = fontLigatures
        self.searchHighlights = searchHighlights
        session.updateRenderState()
        guard let renderState = session.renderState,
              let rowIter = session.rowIterator,
              let cells = session.rowCells
        else {
            presentClear(drawable: drawable, rpd: renderPassDescriptor, clearColor: clearColor)
            return
        }

        let pw = Float(drawableSize.width)
        let ph = Float(drawableSize.height)
        guard pw > 0, ph > 0 else { return }

        // 1:1 device-pixel grid: integer cell size, origin, and pad.
        let cellWInt = max(1, metrics.cellWidthPx)
        let cellHInt = max(1, metrics.cellHeightPx)
        let cellW = Float(cellWInt)
        let cellH = Float(cellHInt)
        let padPx = Float((padPoints * scale).rounded(.toNearestOrAwayFromZero))
        let originX = Float(contentRect.minX.rounded(.toNearestOrAwayFromZero))
        let originY = Float(contentRect.minY.rounded(.toNearestOrAwayFromZero))
        // Snap scroll offset to whole pixels (physics stays continuous).
        let visualY = (Float(visualOffsetRows) * cellH).rounded(.toNearestOrAwayFromZero)
        _ = scale

        var colsU: UInt16 = 0
        var rowsU: UInt16 = 0
        _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_COLS, &colsU)
        _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_ROWS, &rowsU)
        let cols = Int(colsU)
        let rows = Int(rowsU)
        guard cols > 0, rows > 0 else {
            presentClear(drawable: drawable, rpd: renderPassDescriptor, clearColor: clearColor)
            return
        }

        let layout = LayoutKey(
            originX: originX, originY: originY,
            cellW: cellW, cellH: cellH, padPx: padPx,
            cols: cols, rows: rows, fontPx: metrics.fontPx
        )

        // Prewarm ASCII once per font / cell metrics.
        let warmKey = "\(cellWInt)x\(cellHInt)x\(metrics.cellBaselinePx)"
        if prewarmedKey != warmKey {
            atlas.prewarmASCII(
                font: metrics.font,
                boldFont: metrics.fontBold,
                cellWidthPx: cellWInt,
                cellHeightPx: cellHInt,
                cellBaselinePx: metrics.cellBaselinePx,
                faceWidthPx: metrics.faceWidthPx
            )
            prewarmedKey = warmKey
        }

        var colors = GhosttyRenderStateColors()
        colors.size = MemoryLayout<GhosttyRenderStateColors>.size
        _ = ghostty_render_state_colors_get(renderState, &colors)

        var defFg = colors.foreground
        var defBg = colors.background
        // Both zero usually means unset; use host defaults (bg may be black).
        if defFg.r == 0, defFg.g == 0, defFg.b == 0,
           defBg.r == 0, defBg.g == 0, defBg.b == 0 {
            defFg = DefaultColors.foreground
            defBg = DefaultColors.background
        }
        lastDefBg = (defBg.r, defBg.g, defBg.b)

        var dirty = GHOSTTY_RENDER_STATE_DIRTY_FULL
        _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty)

        let blinkOn = cursorBlinkOn(renderState: renderState)
        let blinkChanged = blinkOn != lastBlinkOn
        lastBlinkOn = blinkOn
        let indicatorChanged = indicator != lastIndicator
        lastIndicator = indicator
        let searchHUDChanged = searchHUD != lastSearchHUD
        lastSearchHUD = searchHUD
        let layoutChanged = lastLayoutKey != layout
        let visualChanged = abs(visualY - lastVisualY) > 0.05
        lastVisualY = visualY

        // Cursor can move without dirtying cells (e.g. ← at the shell prompt).
        // Track viewport cursor so we recompose and re-shape run breaks.
        var cursorVisible = false
        var cursorInViewport = false
        var curX: UInt16 = 0
        var curY: UInt16 = 0
        _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE, &cursorVisible)
        _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE, &cursorInViewport)
        if cursorInViewport {
            _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X, &curX)
            _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y, &curY)
        }
        let cursorVis = cursorVisible && cursorInViewport
        let cursorX = cursorVis ? Int(curX) : -1
        let cursorY = cursorVis ? Int(curY) : -1
        let cursorChanged =
            cursorX != lastCursorX
            || cursorY != lastCursorY
            || cursorVis != lastCursorVisible
        lastCursorX = cursorX
        lastCursorY = cursorY
        lastCursorVisible = cursorVis

        var needGridRebuild: Bool
        let partialOnly: Bool
        switch dirty {
        case GHOSTTY_RENDER_STATE_DIRTY_FALSE:
            needGridRebuild = layoutChanged
            partialOnly = false
        case GHOSTTY_RENDER_STATE_DIRTY_PARTIAL:
            needGridRebuild = true
            partialOnly = !layoutChanged && gridCols == cols && gridRows == rows
        default:
            needGridRebuild = true
            partialOnly = false
        }
        // Cursor column affects shaper run breaks; rebuild ink when it moves.
        if cursorChanged {
            needGridRebuild = true
        }
        // Search match ranges change without VT dirty.
        let searchChanged = searchHighlights != lastSearchHighlights
        if searchChanged {
            needGridRebuild = true
            lastSearchHighlights = searchHighlights
        }

        if needGridRebuild {
            // Search highlights / cursor breaks need a full ink pass, not dirty-only.
            if partialOnly && !cursorChanged && !searchChanged {
                rebuildDirtyRows(
                    renderState: renderState,
                    rowIter: rowIter,
                    cells: cells,
                    metrics: metrics,
                    layout: layout,
                    defFg: defFg,
                    defBg: defBg,
                    cellWInt: cellWInt,
                    cellHInt: cellHInt
                )
            } else {
                rebuildAllRows(
                    renderState: renderState,
                    rowIter: rowIter,
                    cells: cells,
                    metrics: metrics,
                    layout: layout,
                    defFg: defFg,
                    defBg: defBg,
                    cellWInt: cellWInt,
                    cellHInt: cellHInt
                )
            }
            lastLayoutKey = layout
        }

        // After grid rebuild so edge samples match this frame's FS TUI cells.
        let letterboxBg = letterboxBackground(defBg: defBg)
        lastLetterboxBg = letterboxBg

        // Idle: reuse previous GPU buffer only when nothing visual moved.
        // Still full-clear with the current letterbox sample (updates when the
        // sample source changes — edge cache / defBg after a dirty rebuild).
        if !needGridRebuild && !blinkChanged && !indicatorChanged && !visualChanged
            && !cursorChanged && !searchHUDChanged && lastDrawnCount > 0 {
            present(
                count: lastDrawnCount,
                drawable: drawable,
                rpd: renderPassDescriptor,
                pw: pw, ph: ph,
                letterboxBg: letterboxBg,
                contentActive: false
            )
            return
        }

        // Compose: grid cells + underlines + cursor + VT indicator + search HUD.
        // Grid positions are base (no scroll offset); apply visualY here.
        // When search sits at top, shift the whole shell down by one cell.
        let shellShiftY: Float = (searchHUD != nil && searchHUDAtTop) ? layout.cellH : 0
        var instances = gridCells
        // Multi-cell ligature ink after cell backgrounds so tails don't cover it.
        instances.append(contentsOf: glyphExtras)
        instances.append(contentsOf: underlineExtras)
        let shellY = visualY + shellShiftY
        if abs(shellY) > 0.001 {
            for i in 0..<instances.count {
                instances[i].oy += shellY
            }
        }

        appendCursor(
            to: &instances,
            renderState: renderState,
            rowIter: rowIter,
            cells: cells,
            colors: colors,
            defFg: defFg,
            metrics: metrics,
            layout: layout,
            cellWInt: cellWInt,
            cellHInt: cellHInt,
            blinkOn: blinkOn,
            visualY: shellY
        )

        if let indicator, !indicator.isEmpty {
            appendIndicator(
                to: &instances,
                text: indicator,
                metrics: metrics,
                layout: layout,
                cellWInt: cellWInt,
                cellHInt: cellHInt,
                // Sit on the shell row, not over a top search HUD.
                yOffset: shellShiftY
            )
        }

        if let searchHUD {
            appendSearchHUD(
                to: &instances,
                line: searchHUD,
                caretCol: searchCaretCol,
                showCaret: blinkOn,
                atTop: searchHUDAtTop,
                metrics: metrics,
                layout: layout,
                cellWInt: cellWInt,
                cellHInt: cellHInt,
                defFg: defFg,
                defBg: defBg
            )
        }

        var clean = GHOSTTY_RENDER_STATE_DIRTY_FALSE
        _ = ghostty_render_state_set(renderState, GHOSTTY_RENDER_STATE_OPTION_DIRTY, &clean)

        uploadInstances(instances)
        lastDrawnCount = instances.count
        present(
            count: instances.count,
            drawable: drawable,
            rpd: renderPassDescriptor,
            pw: pw, ph: ph,
            letterboxBg: letterboxBg,
            contentActive: true
        )
    }

    /// Full-drawable clear color for max-aspect letterbox bars.
    /// Prefer painted edge cells (FS TUI) when the grid exists; else terminal default bg.
    /// Samples `rowCellCache` (pre-selection), never post-invert `gridCells` fill.
    func letterboxBackground(defBg: GhosttyColorRgb) -> GhosttyColorRgb {
        guard gridCols > 0, gridRows > 0, rowCellCache.count >= gridCols * gridRows else {
            return defBg
        }
        // Mid-row left edge sits against the side letterbox on ultra-wide layouts.
        let idx = (gridRows / 2) * gridCols
        return rowCellCache[idx].bg
    }
}
