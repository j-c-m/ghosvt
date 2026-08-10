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
    /// Textured quads for Kitty graphics (RGBA).
    var imagePipeline: MTLRenderPipelineState?
    var sampler: MTLSamplerState
    /// Linear sampler for image content.
    var imageSampler: MTLSamplerState?
    var atlas: GlyphAtlas
    var shaper = ShaperCache()
    var instanceBuffer: MTLBuffer?
    var imageInstanceBuffer: MTLBuffer?
    var uniformBuffer: MTLBuffer?
    var instanceCapacity = 0
    var imageInstanceCapacity = 0
    var floatScratch = [Float]()
    var imageFloatScratch = [Float]()
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
    /// Packed instance count last uploaded (`bg + fg`).
    var lastDrawnCount = 0
    /// Cell-background instance count in the packed GPU buffer.
    var lastBgCount = 0
    /// Glyph / overlay instance count packed after backgrounds.
    var lastFgCount = 0
    var lastLayoutKey: LayoutKey?
    var lastDefBg = (r: DefaultColors.background.r, g: DefaultColors.background.g, b: DefaultColors.background.b)
    private(set) var lastDefFg = DefaultColors.foreground
    private(set) var lastDefBgRgb = DefaultColors.background
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

    /// ⌘-hover link underline (shell viewport coords, inclusive cols).
    struct LinkHoverRange: Equatable {
        var row: Int
        var startX: Int
        var endX: Int
    }
    var linkHover: LinkHoverRange?
    private var lastLinkHover: LinkHoverRange?

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

        if let iv = library.makeFunction(name: "image_vertex"),
           let ifn = library.makeFunction(name: "image_fragment")
        {
            let idesc = MTLRenderPipelineDescriptor()
            idesc.vertexFunction = iv
            idesc.fragmentFunction = ifn
            idesc.colorAttachments[0].pixelFormat = pixelFormat
            idesc.colorAttachments[0].isBlendingEnabled = true
            // Premultiplied: fragment emits rgb*a; source factor is one (Ghostty Metal image path).
            idesc.colorAttachments[0].sourceRGBBlendFactor = .one
            idesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            idesc.colorAttachments[0].sourceAlphaBlendFactor = .one
            idesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            do {
                self.imagePipeline = try device.makeRenderPipelineState(descriptor: idesc)
            } catch {
                fputs("ghosvt: image pipeline failed: \(error)\n", stderr)
            }
        }

        let samp = MTLSamplerDescriptor()
        samp.minFilter = .nearest
        samp.magFilter = .nearest
        samp.sAddressMode = .clampToEdge
        samp.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samp) else { return nil }
        self.sampler = sampler

        let isamp = MTLSamplerDescriptor()
        isamp.minFilter = .linear
        isamp.magFilter = .linear
        isamp.sAddressMode = .clampToEdge
        isamp.tAddressMode = .clampToEdge
        self.imageSampler = device.makeSamplerState(descriptor: isamp)

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
        searchHUDAtTop: Bool = false,
        freezeLetterbox: Bool = false,
        linkHover: LinkHoverRange? = nil
    ) {
        self.fontLigatures = fontLigatures
        self.searchHighlights = searchHighlights
        self.linkHover = linkHover
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
        lastDefFg = defFg
        lastDefBgRgb = defBg

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
        // Freeze while any mouse button is held (tmux reverse-video selection)
        // so side letterbox does not chase inverted edge cells; events still go to the app.
        let letterboxBg: GhosttyColorRgb
        if freezeLetterbox {
            letterboxBg = lastLetterboxBg
        } else {
            letterboxBg = letterboxBackground(defBg: defBg)
            lastLetterboxBg = letterboxBg
        }

        let shellShiftY: Float = (searchHUD != nil && searchHUDAtTop) ? layout.cellH : 0
        let shellY = visualY + shellShiftY

        // Kitty graphics: sync under session lock; textures retained per VT.
        // Geometry always recomputed (scroll / resize); cheap when empty.
        session.syncKittyGraphics(
            device: device,
            layout: layout,
            shellShiftY: shellShiftY,
            visualY: visualY
        )
        let kitty = session.kittyCache
        let hasKitty = !kitty.isEmpty

        // Cells stable: shellY is already baked into the last GPU upload.
        // visualY / search-shift change must re-pack instances (shellY in oy).
        // Kitty may still redraw without re-uploading cells.
        let linkHoverChanged = linkHover != lastLinkHover
        lastLinkHover = linkHover

        let cellsStable = !needGridRebuild && !blinkChanged && !indicatorChanged
            && !cursorChanged && !searchHUDChanged && !visualChanged
            && !linkHoverChanged
            && lastBgCount + lastFgCount > 0
        if cellsStable {
            present(
                bgCount: lastBgCount,
                fgCount: lastFgCount,
                kitty: hasKitty ? kitty : nil,
                drawable: drawable,
                rpd: renderPassDescriptor,
                pw: pw, ph: ph,
                letterboxBg: letterboxBg,
                contentActive: false
            )
            return
        }

        // Compose cell layers separately so Kitty z-layers can interleave:
        // below_bg → cell bg → below_text → glyphs → above_text → overlays.
        var bgInstances = gridCells
        var fgInstances = glyphExtras
        fgInstances.append(contentsOf: underlineExtras)
        // ⌘-hover link underline (text color, font underline metrics).
        if let hover = linkHover {
            appendLinkHoverUnderline(
                to: &fgInstances,
                hover: hover,
                layout: layout,
                metrics: metrics,
                defFg: defFg
            )
        }
        if abs(shellY) > 0.001 {
            for i in 0..<bgInstances.count { bgInstances[i].oy += shellY }
            for i in 0..<fgInstances.count { fgInstances[i].oy += shellY }
        }

        appendCursor(
            to: &fgInstances,
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
                to: &fgInstances,
                text: indicator,
                metrics: metrics,
                layout: layout,
                cellWInt: cellWInt,
                cellHInt: cellHInt,
                yOffset: shellShiftY
            )
        }

        if let searchHUD {
            appendSearchHUD(
                to: &fgInstances,
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

        // Pack [bg | fg] into one buffer; present draws ranges around Kitty layers.
        var packed = bgInstances
        packed.append(contentsOf: fgInstances)
        uploadInstances(packed)
        lastBgCount = bgInstances.count
        lastFgCount = fgInstances.count
        lastDrawnCount = packed.count
        present(
            bgCount: lastBgCount,
            fgCount: lastFgCount,
            kitty: hasKitty ? kitty : nil,
            drawable: drawable,
            rpd: renderPassDescriptor,
            pw: pw, ph: ph,
            letterboxBg: letterboxBg,
            contentActive: true
        )
    }

    /// Paint only the stolen top-row browser address bar (no VT grid).
    func presentBrowserChrome(
        drawable: CAMetalDrawable,
        renderPassDescriptor: MTLRenderPassDescriptor,
        drawableSize: CGSize,
        contentRect: CGRect,
        scale: CGFloat,
        metrics: CellMetrics,
        cols: Int,
        line: String,
        caretCol: Int,
        showCaret: Bool,
        letterboxBg: GhosttyColorRgb,
        defFg: GhosttyColorRgb,
        defBg: GhosttyColorRgb,
        selStartCol: Int = -1,
        selEndCol: Int = -1
    ) {
        let pw = Float(drawableSize.width)
        let ph = Float(drawableSize.height)
        guard pw > 0, ph > 0, cols > 0 else {
            presentClear(drawable: drawable, rpd: renderPassDescriptor, clearColor: MTLClearColor(
                red: Double(letterboxBg.r) / 255,
                green: Double(letterboxBg.g) / 255,
                blue: Double(letterboxBg.b) / 255,
                alpha: 1
            ))
            return
        }
        let cellWInt = max(1, metrics.cellWidthPx)
        let cellHInt = max(1, metrics.cellHeightPx)
        let padPx = Float((padPoints * scale).rounded(.toNearestOrAwayFromZero))
        let layout = LayoutKey(
            originX: Float(contentRect.minX.rounded(.toNearestOrAwayFromZero)),
            originY: Float(contentRect.minY.rounded(.toNearestOrAwayFromZero)),
            cellW: Float(cellWInt),
            cellH: Float(cellHInt),
            padPx: padPx,
            cols: cols,
            rows: 1,
            fontPx: metrics.fontPx
        )
        var instances: [CellInstance] = []
        appendSearchHUD(
            to: &instances,
            line: line,
            caretCol: caretCol,
            showCaret: showCaret,
            atTop: true,
            metrics: metrics,
            layout: layout,
            cellWInt: cellWInt,
            cellHInt: cellHInt,
            defFg: defFg,
            defBg: defBg,
            caretStyle: .themeBlock,
            selStartCol: selStartCol,
            selEndCol: selEndCol
        )
        uploadInstances(instances)
        lastBgCount = 0
        lastFgCount = instances.count
        lastDrawnCount = instances.count
        present(
            bgCount: 0,
            fgCount: instances.count,
            kitty: nil,
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

    /// Underline for ⌘-hover clickable URL (shell viewport row/cols).
    /// Uses each cell’s text (fg) color and CT/font underline thickness + position.
    func appendLinkHoverUnderline(
        to instances: inout [CellInstance],
        hover: LinkHoverRange,
        layout: LayoutKey,
        metrics: CellMetrics,
        defFg: GhosttyColorRgb
    ) {
        guard hover.row >= 0, hover.row < layout.rows else { return }
        let lo = max(0, min(hover.startX, hover.endX))
        let hi = min(layout.cols - 1, max(hover.startX, hover.endX))
        guard lo <= hi else { return }
        let th = Float(max(1, metrics.underlineThicknessPx))
        let y = (layout.originY + layout.padPx + Float(hover.row) * layout.cellH)
            .rounded(.toNearestOrAwayFromZero)
            + Float(metrics.underlineTopPx)
        let defR = Float(defFg.r) / 255
        let defG = Float(defFg.g) / 255
        let defB = Float(defFg.b) / 255
        for col in lo...hi {
            var r = defR, g = defG, b = defB
            let idx = hover.row * layout.cols + col
            if idx >= 0, idx < rowCellCache.count {
                let fg = rowCellCache[idx].fg
                r = Float(fg.r) / 255
                g = Float(fg.g) / 255
                b = Float(fg.b) / 255
            }
            let x = (layout.originX + layout.padPx + Float(col) * layout.cellW)
                .rounded(.toNearestOrAwayFromZero)
            instances.append(.make(
                originX: x,
                originY: y,
                width: layout.cellW,
                height: th,
                u0: 0, v0: 0, u1: 0, v1: 0,
                fr: r, fg: g, fb: b, fa: 1,
                br: r, bg: g, bb: b, ba: 1
            ))
        }
    }
}
