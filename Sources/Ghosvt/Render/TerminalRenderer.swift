import CGhosttyVT
import CoreText
import Foundation
import Metal
import MetalKit
import QuartzCore

/// Metal terminal painter: dirty-aware grid cache + glyph atlas instances.
final class TerminalRenderer {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var pipeline: MTLRenderPipelineState
    private var sampler: MTLSamplerState
    private var atlas: GlyphAtlas
    private var shaper = ShaperCache()
    private var instanceBuffer: MTLBuffer?
    private var uniformBuffer: MTLBuffer?
    private var instanceCapacity = 0
    private var floatScratch = [Float]()
    private var fontLigatures = true

    private let padPoints: CGFloat

    // MARK: Grid cache
    private var gridCells: [CellInstance] = []
    private var gridCols = 0
    private var gridRows = 0
    private var lastDrawnCount = 0
    private var lastLayoutKey: LayoutKey?
    private var lastDefBg = (r: DefaultColors.background.r, g: DefaultColors.background.g, b: DefaultColors.background.b)
    private var lastIndicator: String?
    private var lastBlinkOn = true
    private var lastVisualY: Float = 0
    private var lastCursorX: Int = -1
    private var lastCursorY: Int = -1
    private var lastCursorVisible: Bool = false
    private var blinkPeriod: CFTimeInterval = 0.53
    private var prewarmedKey: String?
    private var loggedNerdFaces = false

    private struct LayoutKey: Equatable {
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
        gridCols = 0
        gridRows = 0
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
        fontLigatures: Bool = true
    ) {
        self.fontLigatures = fontLigatures
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

        if needGridRebuild {
            if partialOnly && !cursorChanged {
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

        // Idle: reuse previous GPU buffer only when nothing visual moved.
        if !needGridRebuild && !blinkChanged && !indicatorChanged && !visualChanged
            && !cursorChanged && lastDrawnCount > 0 {
            present(
                count: lastDrawnCount,
                drawable: drawable,
                rpd: renderPassDescriptor,
                pw: pw, ph: ph,
                defBg: defBg,
                clearColor: clearColor
            )
            return
        }

        // Compose: grid cells + underlines + cursor + VT indicator.
        // Grid positions are base (no scroll offset); apply visualY here.
        var instances = gridCells
        // Multi-cell ligature ink after cell backgrounds so tails don't cover it.
        instances.append(contentsOf: glyphExtras)
        instances.append(contentsOf: underlineExtras)
        if abs(visualY) > 0.001 {
            for i in 0..<instances.count {
                instances[i].oy += visualY
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
            visualY: visualY
        )

        if let indicator, !indicator.isEmpty {
            appendIndicator(
                to: &instances,
                text: indicator,
                metrics: metrics,
                layout: layout,
                cellWInt: cellWInt,
                cellHInt: cellHInt
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
            defBg: defBg,
            clearColor: clearColor
        )
    }

    // MARK: - Grid rebuild

    private func rebuildAllRows(
        renderState: GhosttyRenderState,
        rowIter: GhosttyRenderStateRowIterator,
        cells: GhosttyRenderStateRowCells,
        metrics: CellMetrics,
        layout: LayoutKey,
        defFg: GhosttyColorRgb,
        defBg: GhosttyColorRgb,
        cellWInt: Int,
        cellHInt: Int
    ) {
        gridCols = layout.cols
        gridRows = layout.rows
        gridCells = Array(
            repeating: CellInstance.make(
                originX: 0, originY: 0, width: layout.cellW, height: layout.cellH,
                u0: 0, v0: 0, u1: 0, v1: 0,
                fr: 0, fg: 0, fb: 0, fa: 1,
                br: Float(defBg.r) / 255, bg: Float(defBg.g) / 255, bb: Float(defBg.b) / 255, ba: 1
            ),
            count: layout.cols * layout.rows
        )
        // Also keep decoration instances separate: underlines appended after grid in compose.
        // Bake underlines into a parallel array rebuilt with grid.
        underlineExtras = []
        glyphExtras = []
        rebuildRows(
            renderState: renderState,
            rowIter: rowIter,
            cells: cells,
            metrics: metrics,
            layout: layout,
            defFg: defFg,
            defBg: defBg,
            cellWInt: cellWInt,
            cellHInt: cellHInt,
            onlyDirty: false
        )
    }

    private var underlineExtras: [CellInstance] = []
    /// Multi-cell ligature ink drawn after all cell backgrounds.
    private var glyphExtras: [CellInstance] = []

    private func rebuildDirtyRows(
        renderState: GhosttyRenderState,
        rowIter: GhosttyRenderStateRowIterator,
        cells: GhosttyRenderStateRowCells,
        metrics: CellMetrics,
        layout: LayoutKey,
        defFg: GhosttyColorRgb,
        defBg: GhosttyColorRgb,
        cellWInt: Int,
        cellHInt: Int
    ) {
        // Ink lives in glyphExtras (global). Always repaint every row so scroll /
        // partial dirty cannot wipe clean rows' text.
        underlineExtras = []
        glyphExtras = []
        rebuildRows(
            renderState: renderState,
            rowIter: rowIter,
            cells: cells,
            metrics: metrics,
            layout: layout,
            defFg: defFg,
            defBg: defBg,
            cellWInt: cellWInt,
            cellHInt: cellHInt,
            onlyDirty: false
        )
    }

    private func rebuildRows(
        renderState: GhosttyRenderState,
        rowIter: GhosttyRenderStateRowIterator,
        cells: GhosttyRenderStateRowCells,
        metrics: CellMetrics,
        layout: LayoutKey,
        defFg: GhosttyColorRgb,
        defBg: GhosttyColorRgb,
        cellWInt: Int,
        cellHInt: Int,
        onlyDirty: Bool
    ) {
        var iter = rowIter
        _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &iter)

        var rowIndex = 0
        while ghostty_render_state_row_iterator_next(iter) {
            defer { rowIndex += 1 }
            guard rowIndex < layout.rows else { break }

            var cellsHandle = cells
            if ghostty_render_state_row_get(iter, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cellsHandle) != GHOSTTY_SUCCESS {
                continue
            }

            let rowCells = collectRowCells(
                cellsHandle: cellsHandle,
                layout: layout,
                defFg: defFg,
                defBg: defBg
            )
            paintRow(
                rowCells: rowCells,
                rowIndex: rowIndex,
                metrics: metrics,
                layout: layout,
                cellWInt: cellWInt,
                cellHInt: cellHInt,
                renderState: renderState,
                rowIter: iter
            )

            var clean = false
            _ = ghostty_render_state_row_set(iter, GHOSTTY_RENDER_STATE_ROW_OPTION_DIRTY, &clean)
        }
        _ = onlyDirty
    }

    // MARK: - Run segmentation + shaped paint

    private struct RowCell {
        var text: String
        var isWideHead: Bool
        var isWideTail: Bool
        var fg: GhosttyColorRgb
        var bg: GhosttyColorRgb
        var bold: Bool
        var italic: Bool
        var faint: Bool
        var inverse: Bool
        var underline: Bool

        var isSpaceOrEmpty: Bool {
            if isWideHead || isWideTail { return false }
            if text.isEmpty { return true }
            return text == " " || text == "\u{00A0}"
        }

        var textStyle: TextStyleKey {
            TextStyleKey(
                fr: fg.r, fg: fg.g, fb: fg.b,
                bold: bold, italic: italic, faint: faint,
                inverse: inverse, underline: underline
            )
        }
    }

    private func collectRowCells(
        cellsHandle: GhosttyRenderStateRowCells,
        layout: LayoutKey,
        defFg: GhosttyColorRgb,
        defBg: GhosttyColorRgb
    ) -> [RowCell] {
        var out: [RowCell] = []
        out.reserveCapacity(layout.cols)
        var skipTail = false
        var col = 0
        while ghostty_render_state_row_cells_next(cellsHandle) {
            defer { col += 1 }
            guard col < layout.cols else { break }

            var isWideHead = false
            var isWideTail = false
            if skipTail {
                isWideTail = true
                skipTail = false
            } else {
                var rawCell: GhosttyCell = 0
                if ghostty_render_state_row_cells_get(
                    cellsHandle,
                    GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW,
                    &rawCell
                ) == GHOSTTY_SUCCESS {
                    var wide: GhosttyCellWide = GHOSTTY_CELL_WIDE_NARROW
                    if ghostty_cell_get(rawCell, GHOSTTY_CELL_DATA_WIDE, &wide) == GHOSTTY_SUCCESS {
                        if wide == GHOSTTY_CELL_WIDE_SPACER_TAIL {
                            isWideTail = true
                        } else if wide == GHOSTTY_CELL_WIDE_WIDE {
                            isWideHead = true
                            skipTail = true
                        }
                    }
                }
            }

            var fg = defFg
            _ = ghostty_render_state_row_cells_get(
                cellsHandle, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &fg
            )
            var bgCell = defBg
            let hasBg = ghostty_render_state_row_cells_get(
                cellsHandle, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &bgCell
            ) == GHOSTTY_SUCCESS

            var style = GhosttyStyle()
            style.size = MemoryLayout<GhosttyStyle>.size
            ghostty_style_default(&style)
            _ = ghostty_render_state_row_cells_get(
                cellsHandle, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style
            )
            if style.inverse {
                swap(&fg, &bgCell)
            }
            let bg = (hasBg || style.inverse) ? bgCell : defBg
            let text = cellTextUTF8(cellsHandle) ?? ""

            out.append(RowCell(
                text: text,
                isWideHead: isWideHead,
                isWideTail: isWideTail,
                fg: fg,
                bg: bg,
                bold: style.bold,
                italic: style.italic,
                faint: style.faint,
                inverse: style.inverse,
                underline: style.underline != 0
            ))
        }
        while out.count < layout.cols {
            out.append(RowCell(
                text: "", isWideHead: false, isWideTail: false,
                fg: defFg, bg: defBg,
                bold: false, italic: false, faint: false, inverse: false, underline: false
            ))
        }
        return out
    }

    private func paintRow(
        rowCells: [RowCell],
        rowIndex: Int,
        metrics: CellMetrics,
        layout: LayoutKey,
        cellWInt: Int,
        cellHInt: Int,
        renderState: GhosttyRenderState,
        rowIter: GhosttyRenderStateRowIterator
    ) {
        let y = (layout.originY + layout.padPx + Float(rowIndex) * layout.cellH)
            .rounded(.toNearestOrAwayFromZero)
        var selStart: Int?
        var selEnd: Int?
        var rowSel = GhosttyRenderStateRowSelection()
        rowSel.size = MemoryLayout<GhosttyRenderStateRowSelection>.size
        if ghostty_render_state_row_get(
            rowIter,
            GHOSTTY_RENDER_STATE_ROW_DATA_SELECTION,
            &rowSel
        ) == GHOSTTY_SUCCESS {
            selStart = Int(rowSel.start_x)
            selEnd = Int(rowSel.end_x)
        }

        func selected(_ col: Int) -> Bool {
            guard let s = selStart, let e = selEnd else { return false }
            return col >= min(s, e) && col <= max(s, e)
        }

        // 1) Background for every cell (selection invert on bg/fg pair for empty ink).
        for col in 0..<layout.cols {
            let c = rowCells[col]
            let x = (layout.originX + layout.padPx + Float(col) * layout.cellW)
                .rounded(.toNearestOrAwayFromZero)
            let yPx = y
            var fr = Float(c.fg.r) / 255
            var fgG = Float(c.fg.g) / 255
            var fb = Float(c.fg.b) / 255
            if c.faint { fr *= 0.5; fgG *= 0.5; fb *= 0.5 }
            var br = Float(c.bg.r) / 255
            var bgG = Float(c.bg.g) / 255
            var bb = Float(c.bg.b) / 255
            if selected(col) {
                swap(&fr, &br); swap(&fgG, &bgG); swap(&fb, &bb)
            }
            let idx = rowIndex * layout.cols + col
            if idx < gridCells.count {
                gridCells[idx] = CellInstance.make(
                    originX: x, originY: yPx,
                    width: layout.cellW, height: layout.cellH,
                    u0: 0, v0: 0, u1: 0, v1: 0,
                    fr: fr, fg: fgG, fb: fb, fa: 1,
                    br: br, bg: bgG, bb: bb, ba: 1
                )
            }
            if c.underline {
                let th = max(1, layout.cellH * 0.06)
                underlineExtras.append(.make(
                    originX: x, originY: y + layout.cellH - th - 1,
                    width: layout.cellW, height: th,
                    u0: 0, v0: 0, u1: 0, v1: 0,
                    fr: fr, fg: fgG, fb: fb, fa: 1,
                    br: fr, bg: fgG, bb: fb, ba: 1
                ))
            }
        }

        // Cursor on this row → break runs around that column (Ghostty).
        var cursorCol: Int?
        var inViewport = false
        var cy: UInt16 = 0
        var cx: UInt16 = 0
        _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE, &inViewport)
        if inViewport {
            _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X, &cx)
            _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y, &cy)
            if Int(cy) == rowIndex {
                cursorCol = Int(cx)
            }
        }

        // 2) Shape text runs and stamp glyphs.
        let segments = segmentRuns(
            rowCells,
            selectionLo: selStart.flatMap { s in selEnd.map { e in min(s, e) } },
            selectionHi: selStart.flatMap { s in selEnd.map { e in max(s, e) } },
            cursorCol: cursorCol
        )
        for seg in segments {
            switch seg {
            case .gap:
                break
            case .wide(let col):
                paintWideOrFallback(
                    col: col, rowIndex: rowIndex, rowCells: rowCells,
                    metrics: metrics, layout: layout,
                    cellWInt: cellWInt, cellHInt: cellHInt, selected: selected(col)
                )
            case .run(let start, let end, let style):
                paintShapedRun(
                    start: start, end: end, style: style,
                    rowCells: rowCells, rowIndex: rowIndex,
                    metrics: metrics, layout: layout,
                    cellWInt: cellWInt, cellHInt: cellHInt,
                    selected: selected
                )
            }
        }
    }

    private enum RunSeg {
        case run(start: Int, end: Int, style: TextStyleKey) // end exclusive
        case wide(col: Int)
        case gap
    }

    /// Segment a row into shape runs (Ghostty-aligned break rules).
    ///
    /// Breaks on: 2+ spaces/empties, text style (not bg), wide cells,
    /// selection boundaries, cursor column, and bad ligatures (fi/fl/st).
    /// Single spaces stay inside runs; 2+ spaces are gaps.
    private func segmentRuns(
        _ cells: [RowCell],
        selectionLo: Int?,
        selectionHi: Int?,
        cursorCol: Int?
    ) -> [RunSeg] {
        var segs: [RunSeg] = []
        var i = 0
        var runStart: Int?
        var runStyle: TextStyleKey?

        func flushRun(upTo end: Int) {
            guard let s = runStart, let st = runStyle, s < end else {
                runStart = nil
                runStyle = nil
                return
            }
            segs.append(.run(start: s, end: end, style: st))
            runStart = nil
            runStyle = nil
        }

        /// True if we must end the current run before absorbing column `i`.
        func mustBreakBefore(i: Int, runStart: Int) -> Bool {
            if i <= runStart { return false }

            // Selection: break at enter (lo) and leave (hi+1). Inclusive hi.
            if let lo = selectionLo, let hi = selectionHi {
                if i == lo { return true }
                if i == hi + 1 { return true }
            }

            // Cursor: run before cursor stops at cursor; cursor cell is its own run.
            if let cx = cursorCol {
                // Started before cursor, about to include cursor → stop before it.
                if runStart < cx, i == cx { return true }
                // Started at cursor, already took cursor cell → stop after one cell.
                if runStart == cx, i == runStart + 1 { return true }
            }

            // Bad ligatures (Ghostty): force split so fi/fl/st do not merge.
            if Self.isBadLigaturePair(prev: cells[i - 1], next: cells[i]) {
                return true
            }

            return false
        }

        while i < cells.count {
            let c = cells[i]
            if c.isWideTail {
                i += 1
                continue
            }
            if c.isWideHead {
                flushRun(upTo: i)
                segs.append(.wide(col: i))
                i += 1
                continue
            }

            // Count consecutive space/empty cells.
            if c.isSpaceOrEmpty {
                var j = i
                while j < cells.count, cells[j].isSpaceOrEmpty, !cells[j].isWideHead, !cells[j].isWideTail {
                    j += 1
                }
                let n = j - i
                if n >= 2 {
                    flushRun(upTo: i)
                    segs.append(.gap)
                    i = j
                    continue
                }
                // Single space: include in run if style matches (or start run).
            }

            if let s = runStart, mustBreakBefore(i: i, runStart: s) {
                flushRun(upTo: i)
            }

            let st = c.textStyle
            if runStart == nil {
                runStart = i
                runStyle = st
            } else if st != runStyle {
                flushRun(upTo: i)
                runStart = i
                runStyle = st
            }
            i += 1
        }
        flushRun(upTo: cells.count)
        return segs
    }

    /// Ghostty "bad ligature" pairs: fi, fl, st (common discretionary ligas).
    private static func isBadLigaturePair(prev: RowCell, next: RowCell) -> Bool {
        guard let a = prev.text.first, let b = next.text.first else { return false }
        // Only plain single-scalar cells (skip multi-codepoint graphemes).
        guard prev.text.count == 1, next.text.count == 1 else { return false }
        switch (a, b) {
        case ("f", "i"), ("f", "l"), ("s", "t"),
             ("F", "i"), ("F", "l"), ("S", "t"),
             ("f", "I"), ("f", "L"), ("s", "T"),
             ("F", "I"), ("F", "L"), ("S", "T"):
            return true
        default:
            return false
        }
    }

    private func paintShapedRun(
        start: Int,
        end: Int,
        style: TextStyleKey,
        rowCells: [RowCell],
        rowIndex: Int,
        metrics: CellMetrics,
        layout: LayoutKey,
        cellWInt: Int,
        cellHInt: Int,
        selected: (Int) -> Bool
    ) {
        guard start < end else { return }

        let font = metrics.font(bold: style.bold, italic: style.italic)
        let shapedFont = ShaperCache.font(font, ligatures: fontLigatures)
        let nerdFaces = EmbeddedFonts.nerdFaces(size: CTFontGetSize(metrics.font))

        // Ligatures only when every cell is a normal primary-face glyph.
        // Sprites (braille/box/blocks/…), Nerd PUA, and missing maps are cell-by-cell.
        let allPrimary = (start..<end).allSatisfy { col in
            let t = rowCells[col].text
            if t.isEmpty { return true }
            if SpriteFace.covers(text: t) { return false }
            if GlyphAtlas.isPrivateUse(t) { return false }
            return GlyphAtlas.fontCovers(shapedFont, text: t)
        }

        if allPrimary {
            paintLigatureRun(
                start: start, end: end, style: style, rowCells: rowCells,
                rowIndex: rowIndex, metrics: metrics, layout: layout,
                cellWInt: cellWInt, cellHInt: cellHInt, selected: selected,
                shapedFont: shapedFont
            )
            return
        }

        paintCellsIndividually(
            start: start, end: end, style: style, rowCells: rowCells,
            rowIndex: rowIndex, metrics: metrics, layout: layout,
            cellWInt: cellWInt, cellHInt: cellHInt, selected: selected,
            primary: shapedFont, nerdFaces: nerdFaces
        )
    }

    /// Shape the whole run (liga/calt) and draw shaper glyphs — primary face only.
    private func paintLigatureRun(
        start: Int,
        end: Int,
        style: TextStyleKey,
        rowCells: [RowCell],
        rowIndex: Int,
        metrics: CellMetrics,
        layout: LayoutKey,
        cellWInt: Int,
        cellHInt: Int,
        selected: (Int) -> Bool,
        shapedFont: CTFont
    ) {
        var text = ""
        var utf16Starts: [Int] = [0]
        for col in start..<end {
            let t = rowCells[col].text.isEmpty ? " " : rowCells[col].text
            text += t
            utf16Starts.append(text.utf16.count)
        }
        guard !text.isEmpty else { return }

        let placements = shaper.shape(
            text: text,
            cellUTF16Starts: utf16Starts,
            style: style,
            font: shapedFont,
            fontPx: layout.fontPx,
            ligatures: fontLigatures
        )

        let rowTop = (layout.originY + layout.padPx + Float(rowIndex) * layout.cellH)
            .rounded(.toNearestOrAwayFromZero)
        var fr = Float(style.fr) / 255
        var fgG = Float(style.fg) / 255
        var fb = Float(style.fb) / 255
        if style.faint { fr *= 0.5; fgG *= 0.5; fb *= 0.5 }

        for p in placements {
            let col = start + Int(p.x)
            guard col < end, col < layout.cols else { continue }
            let entry = atlas.entry(
                glyph: p.glyph,
                bold: style.bold,
                italic: style.italic,
                font: shapedFont,
                fontPx: layout.fontPx,
                cellHeightPx: cellHInt,
                cellBaselinePx: metrics.cellBaselinePx,
                cellWidthPx: cellWInt,
                faceWidthPx: metrics.faceWidthPx
            )
            if entry.pixelW < 0.5 || entry.pixelH < 0.5 { continue }
            appendGlyphExtra(
                entry: entry,
                col: col, rowIndex: rowIndex, rowTop: rowTop,
                xOffset: Float(p.xOffset), yOffset: Float(p.yOffset),
                fr: fr, fg: fgG, fb: fb,
                layout: layout, selected: selected
            )
        }
    }

    /// One glyph (or text fallback) per cell — Nerd PUA and missing primary maps.
    private func paintCellsIndividually(
        start: Int,
        end: Int,
        style: TextStyleKey,
        rowCells: [RowCell],
        rowIndex: Int,
        metrics: CellMetrics,
        layout: LayoutKey,
        cellWInt: Int,
        cellHInt: Int,
        selected: (Int) -> Bool,
        primary: CTFont,
        nerdFaces: [CTFont]
    ) {
        if !loggedNerdFaces {
            loggedNerdFaces = true
            let names = nerdFaces.map { (CTFontCopyPostScriptName($0) as String?) ?? "?" }
            fputs(
                "ghosvt: nerd faces loaded=\(nerdFaces.count) \(names) fontPx=\(layout.fontPx)\n",
                stderr
            )
        }

        let rowTop = (layout.originY + layout.padPx + Float(rowIndex) * layout.cellH)
            .rounded(.toNearestOrAwayFromZero)
        var fr = Float(style.fr) / 255
        var fgG = Float(style.fg) / 255
        var fb = Float(style.fb) / 255
        if style.faint { fr *= 0.5; fgG *= 0.5; fb *= 0.5 }

        for col in start..<end {
            guard col < layout.cols else { continue }
            let cellText = rowCells[col].text
            if cellText.isEmpty { continue }

            let entry: GlyphAtlas.Entry
            if let cp = cellText.unicodeScalars.first?.value,
               cellText.unicodeScalars.count == 1,
               SpriteFace.covers(cp) {
                // Ghostty sprite face: braille, box drawing, blocks, powerline, …
                entry = atlas.entrySprite(
                    codepoint: cp,
                    cellWidthPx: cellWInt,
                    cellHeightPx: cellHInt,
                    cellBaselinePx: metrics.cellBaselinePx
                )
            } else if let resolved = resolveGlyphFace(
                text: cellText, primary: primary, nerdFaces: nerdFaces
            ) {
                entry = atlas.entry(
                    glyph: resolved.glyph,
                    bold: style.bold,
                    italic: style.italic,
                    font: resolved.font,
                    fontPx: layout.fontPx,
                    cellHeightPx: cellHInt,
                    cellBaselinePx: metrics.cellBaselinePx,
                    cellWidthPx: cellWInt,
                    faceWidthPx: metrics.faceWidthPx
                )
            } else {
                entry = atlas.entry(
                    text: cellText,
                    bold: style.bold,
                    italic: style.italic,
                    font: primary,
                    cellWidthPx: cellWInt,
                    cellHeightPx: cellHInt,
                    cellBaselinePx: metrics.cellBaselinePx,
                    faceWidthPx: metrics.faceWidthPx,
                    fallbackFonts: nerdFaces
                )
            }
            // U+2800 (blank braille) and missing glyphs: skip ink.
            if entry.pixelW < 0.5 || entry.pixelH < 0.5 { continue }
            appendGlyphExtra(
                entry: entry,
                col: col, rowIndex: rowIndex, rowTop: rowTop,
                xOffset: 0, yOffset: 0,
                fr: fr, fg: fgG, fb: fb,
                layout: layout, selected: selected
            )
        }
    }

    private func appendGlyphExtra(
        entry: GlyphAtlas.Entry,
        col: Int,
        rowIndex: Int,
        rowTop: Float,
        xOffset: Float,
        yOffset: Float,
        fr: Float, fg: Float, fb: Float,
        layout: LayoutKey,
        selected: (Int) -> Bool
    ) {
        let cellX = (layout.originX + layout.padPx + Float(col) * layout.cellW)
            .rounded(.toNearestOrAwayFromZero)
        let ox = (cellX + xOffset + entry.bearingX).rounded(.toNearestOrAwayFromZero)
        let oy = (rowTop + entry.bearingY - yOffset).rounded(.toNearestOrAwayFromZero)
        let pwG = entry.pixelW.rounded(.toNearestOrAwayFromZero)
        let phG = entry.pixelH.rounded(.toNearestOrAwayFromZero)

        // Selection: grid cell was fg/bg swapped (selection-bg = cell-fg,
        // selection-fg = cell-bg). Ink must use the post-swap *foreground*
        // (fr), not br — br is the selection fill and would make text vanish.
        var ifr = fr, ifg = fg, ifb = fb
        if selected(col) {
            let idx = rowIndex * layout.cols + col
            if idx < gridCells.count {
                let cell = gridCells[idx]
                ifr = cell.fr; ifg = cell.fg; ifb = cell.fb
            }
        }

        glyphExtras.append(.make(
            originX: ox, originY: oy,
            width: max(1, pwG), height: max(1, phG),
            u0: entry.uv.x, v0: entry.uv.y, u1: entry.uv.z, v1: entry.uv.w,
            fr: ifr, fg: ifg, fb: ifb, fa: 1,
            br: 0, bg: 0, bb: 0, ba: 0
        ))
    }

    /// Best face + single glyph for a cell: Nerd for PUA / missing primary, else primary.
    private func resolveGlyphFace(
        text: String,
        primary: CTFont,
        nerdFaces: [CTFont]
    ) -> (font: CTFont, glyph: CGGlyph)? {
        guard !text.isEmpty else { return nil }
        let preferNerd =
            GlyphAtlas.isPrivateUse(text) || !GlyphAtlas.fontCovers(primary, text: text)
        let order = preferNerd ? (nerdFaces + [primary]) : ([primary] + nerdFaces)
        for face in order {
            guard let glyphs = GlyphAtlas.glyphs(for: text, font: face), glyphs.count == 1 else {
                continue
            }
            return (face, glyphs[0])
        }
        return nil
    }

    private func nerdFallbackFonts(metrics: CellMetrics) -> [CTFont] {
        EmbeddedFonts.nerdFaces(size: CTFontGetSize(metrics.font))
    }

    private func paintWideOrFallback(
        col: Int,
        rowIndex: Int,
        rowCells: [RowCell],
        metrics: CellMetrics,
        layout: LayoutKey,
        cellWInt: Int,
        cellHInt: Int,
        selected: Bool
    ) {
        guard col < rowCells.count else { return }
        let c = rowCells[col]
        let text = c.text
        guard !text.isEmpty else { return }
        let font = metrics.font(bold: c.bold, italic: c.italic)
        let span = c.isWideHead ? 2 : 1
        let entry = atlas.entry(
            text: text,
            bold: c.bold,
            italic: c.italic,
            font: font,
            cellWidthPx: cellWInt * span,
            cellHeightPx: cellHInt,
            cellBaselinePx: metrics.cellBaselinePx,
            faceWidthPx: metrics.faceWidthPx * CGFloat(span),
            fallbackFonts: nerdFallbackFonts(metrics: metrics)
        )
        let x = layout.originX + layout.padPx + Float(col) * layout.cellW
        let y = layout.originY + layout.padPx + Float(rowIndex) * layout.cellH
        var fr = Float(c.fg.r) / 255
        var fgG = Float(c.fg.g) / 255
        var fb = Float(c.fg.b) / 255
        if c.faint { fr *= 0.5; fgG *= 0.5; fb *= 0.5 }
        var br = Float(c.bg.r) / 255
        var bgG = Float(c.bg.g) / 255
        var bb = Float(c.bg.b) / 255
        if selected {
            swap(&fr, &br); swap(&fgG, &bgG); swap(&fb, &bb)
        }
        let idx = rowIndex * layout.cols + col
        guard idx < gridCells.count else { return }
        gridCells[idx] = CellInstance.make(
            originX: x, originY: y,
            width: layout.cellW * Float(span),
            height: layout.cellH,
            u0: entry.uv.x, v0: entry.uv.y, u1: entry.uv.z, v1: entry.uv.w,
            fr: fr, fg: fgG, fb: fb, fa: 1,
            br: br, bg: bgG, bb: bb, ba: 1
        )
    }

    private func rebuildRowUnderlinesOnly(
        cellsHandle: GhosttyRenderStateRowCells,
        rowIndex: Int,
        layout: LayoutKey,
        defFg: GhosttyColorRgb,
        defBg: GhosttyColorRgb
    ) {
        var col = 0
        while ghostty_render_state_row_cells_next(cellsHandle) {
            defer { col += 1 }
            guard col < layout.cols else { break }
            appendUnderlineIfNeeded(
                cellsHandle: cellsHandle,
                row: rowIndex, col: col,
                layout: layout, defFg: defFg, defBg: defBg
            )
        }
    }

    private struct CellBuild {
        var cell: CellInstance
        var underline: CellInstance?
    }

    private func makeCellInstance(
        cellsHandle: GhosttyRenderStateRowCells,
        x: Float, y: Float,
        layout: LayoutKey,
        metrics: CellMetrics,
        defFg: GhosttyColorRgb,
        defBg: GhosttyColorRgb,
        cellWInt: Int,
        cellHInt: Int,
        wide: Bool
    ) -> CellBuild {
        var graphemeLen: UInt32 = 0
        _ = ghostty_render_state_row_cells_get(
            cellsHandle,
            GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN,
            &graphemeLen
        )

        var fg = defFg
        _ = ghostty_render_state_row_cells_get(
            cellsHandle,
            GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR,
            &fg
        )
        var bgCell = defBg
        let hasBg = ghostty_render_state_row_cells_get(
            cellsHandle,
            GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR,
            &bgCell
        ) == GHOSTTY_SUCCESS

        var style = GhosttyStyle()
        style.size = MemoryLayout<GhosttyStyle>.size
        ghostty_style_default(&style)
        _ = ghostty_render_state_row_cells_get(
            cellsHandle,
            GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE,
            &style
        )

        if style.inverse {
            swap(&fg, &bgCell)
        }

        let bgRGB = (hasBg || style.inverse) ? bgCell : defBg
        var fr = Float(fg.r) / 255
        var fgG = Float(fg.g) / 255
        var fb = Float(fg.b) / 255
        if style.faint {
            fr *= 0.5; fgG *= 0.5; fb *= 0.5
        }

        var u0: Float = 0, v0: Float = 0, u1: Float = 0, v1: Float = 0
        if graphemeLen > 0, let str = cellTextUTF8(cellsHandle), !str.isEmpty {
            let font = metrics.font(bold: style.bold, italic: style.italic)
            let span = wide ? 2 : 1
            let entry = atlas.entry(
                text: str,
                bold: style.bold,
                italic: style.italic,
                font: font,
                cellWidthPx: cellWInt * span,
                cellHeightPx: cellHInt,
                cellBaselinePx: metrics.cellBaselinePx,
                faceWidthPx: metrics.faceWidthPx * CGFloat(span),
                fallbackFonts: nerdFallbackFonts(metrics: metrics)
            )
            u0 = entry.uv.x
            v0 = entry.uv.y
            u1 = entry.uv.z
            v1 = entry.uv.w
        }

        let cellW = wide ? layout.cellW * 2 : layout.cellW
        let cell = CellInstance.make(
            originX: x, originY: y,
            width: cellW, height: layout.cellH,
            u0: u0, v0: v0, u1: u1, v1: v1,
            fr: fr, fg: fgG, fb: fb, fa: 1,
            br: Float(bgRGB.r) / 255, bg: Float(bgRGB.g) / 255, bb: Float(bgRGB.b) / 255, ba: 1
        )

        var underline: CellInstance?
        if style.underline != 0 {
            let th = max(1, layout.cellH * 0.06)
            underline = CellInstance.make(
                originX: x,
                originY: y + layout.cellH - th - 1,
                width: cellW,
                height: th,
                u0: 0, v0: 0, u1: 0, v1: 0,
                fr: fr, fg: fgG, fb: fb, fa: 1,
                br: fr, bg: fgG, bb: fb, ba: 1
            )
        }

        return CellBuild(cell: cell, underline: underline)
    }

    private func appendUnderlineIfNeeded(
        cellsHandle: GhosttyRenderStateRowCells,
        row: Int, col: Int,
        layout: LayoutKey,
        defFg: GhosttyColorRgb,
        defBg: GhosttyColorRgb
    ) {
        var style = GhosttyStyle()
        style.size = MemoryLayout<GhosttyStyle>.size
        ghostty_style_default(&style)
        _ = ghostty_render_state_row_cells_get(
            cellsHandle,
            GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE,
            &style
        )
        guard style.underline != 0 else { return }
        var fg = defFg
        _ = ghostty_render_state_row_cells_get(
            cellsHandle,
            GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR,
            &fg
        )
        if style.inverse {
            var bg = defBg
            _ = ghostty_render_state_row_cells_get(
                cellsHandle,
                GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR,
                &bg
            )
            fg = bg
        }
        if style.faint {
            fg.r = UInt8(Float(fg.r) * 0.5)
            fg.g = UInt8(Float(fg.g) * 0.5)
            fg.b = UInt8(Float(fg.b) * 0.5)
        }
        let x = layout.originX + layout.padPx + Float(col) * layout.cellW
        let y = layout.originY + layout.padPx + Float(row) * layout.cellH
        let th = max(1, layout.cellH * 0.06)
        let fr = Float(fg.r) / 255
        let fgG = Float(fg.g) / 255
        let fb = Float(fg.b) / 255
        underlineExtras.append(.make(
            originX: x, originY: y + layout.cellH - th - 1,
            width: layout.cellW, height: th,
            u0: 0, v0: 0, u1: 0, v1: 0,
            fr: fr, fg: fgG, fb: fb, fa: 1,
            br: fr, bg: fgG, bb: fb, ba: 1
        ))
    }

    private func rebuildAllUnderlines(
        renderState: GhosttyRenderState,
        rowIter: GhosttyRenderStateRowIterator,
        cells: GhosttyRenderStateRowCells,
        layout: LayoutKey,
        defFg: GhosttyColorRgb,
        defBg: GhosttyColorRgb
    ) {
        var iter = rowIter
        _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &iter)
        var rowIndex = 0
        while ghostty_render_state_row_iterator_next(iter) {
            defer { rowIndex += 1 }
            guard rowIndex < layout.rows else { break }
            var cellsHandle = cells
            if ghostty_render_state_row_get(iter, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cellsHandle) != GHOSTTY_SUCCESS {
                continue
            }
            var col = 0
            while ghostty_render_state_row_cells_next(cellsHandle) {
                defer { col += 1 }
                guard col < layout.cols else { break }
                appendUnderlineIfNeeded(
                    cellsHandle: cellsHandle,
                    row: rowIndex, col: col,
                    layout: layout, defFg: defFg, defBg: defBg
                )
            }
        }
    }

    // MARK: - Cursor

    private func cursorBlinkOn(renderState: GhosttyRenderState) -> Bool {
        var blinking = false
        _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_BLINKING, &blinking)
        guard blinking else { return true }
        let t = CACurrentMediaTime()
        return Int(t / blinkPeriod) % 2 == 0
    }

    private func appendCursor(
        to instances: inout [CellInstance],
        renderState: GhosttyRenderState,
        rowIter: GhosttyRenderStateRowIterator,
        cells: GhosttyRenderStateRowCells,
        colors: GhosttyRenderStateColors,
        defFg: GhosttyColorRgb,
        metrics: CellMetrics,
        layout: LayoutKey,
        cellWInt: Int,
        cellHInt: Int,
        blinkOn: Bool,
        visualY: Float = 0
    ) {
        var cursorVisible = false
        var inViewport = false
        _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE, &cursorVisible)
        _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE, &inViewport)
        guard cursorVisible, inViewport, blinkOn else { return }

        var cx: UInt16 = 0
        var cy: UInt16 = 0
        _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X, &cx)
        _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y, &cy)

        var style = GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK
        _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE, &style)

        // Host theme: cursor = cell-foreground (#ccc). Prefer explicit terminal
        // cursor color; otherwise DefaultColors.cursor / defFg.
        var cur = DefaultColors.cursor
        if colors.cursor_has_value {
            cur = colors.cursor
        } else if defFg.r != 0 || defFg.g != 0 || defFg.b != 0 {
            cur = defFg
        }
        let cr = Float(cur.r) / 255
        let cg = Float(cur.g) / 255
        let cb = Float(cur.b) / 255
        // cursor-text = cell-background (glyph under block).
        let tr = Float(DefaultColors.background.r) / 255
        let tg = Float(DefaultColors.background.g) / 255
        let tb = Float(DefaultColors.background.b) / 255
        let x = (layout.originX + layout.padPx + Float(cx) * layout.cellW)
            .rounded(.toNearestOrAwayFromZero)
        let y = (layout.originY + layout.padPx + Float(cy) * layout.cellH + visualY)
            .rounded(.toNearestOrAwayFromZero)
        let cw = layout.cellW
        let ch = layout.cellH

        switch style {
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR:
            let w = max(2, cw * 0.12).rounded(.toNearestOrAwayFromZero)
            instances.append(.make(
                originX: x, originY: y, width: w, height: ch,
                u0: 0, v0: 0, u1: 0, v1: 0,
                fr: cr, fg: cg, fb: cb, fa: 1,
                br: cr, bg: cg, bb: cb, ba: 1
            ))
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE:
            let h = max(2, ch * 0.12).rounded(.toNearestOrAwayFromZero)
            instances.append(.make(
                originX: x, originY: y + ch - h, width: cw, height: h,
                u0: 0, v0: 0, u1: 0, v1: 0,
                fr: cr, fg: cg, fb: cb, fa: 1,
                br: cr, bg: cg, bb: cb, ba: 1
            ))
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW:
            let t: Float = max(1, min(cw, ch) * 0.08).rounded(.toNearestOrAwayFromZero)
            instances.append(.make(originX: x, originY: y, width: cw, height: t, u0: 0, v0: 0, u1: 0, v1: 0, fr: cr, fg: cg, fb: cb, fa: 1, br: cr, bg: cg, bb: cb, ba: 1))
            instances.append(.make(originX: x, originY: y + ch - t, width: cw, height: t, u0: 0, v0: 0, u1: 0, v1: 0, fr: cr, fg: cg, fb: cb, fa: 1, br: cr, bg: cg, bb: cb, ba: 1))
            instances.append(.make(originX: x, originY: y, width: t, height: ch, u0: 0, v0: 0, u1: 0, v1: 0, fr: cr, fg: cg, fb: cb, fa: 1, br: cr, bg: cg, bb: cb, ba: 1))
            instances.append(.make(originX: x + cw - t, originY: y, width: t, height: ch, u0: 0, v0: 0, u1: 0, v1: 0, fr: cr, fg: cg, fb: cb, fa: 1, br: cr, bg: cg, bb: cb, ba: 1))
        default: // block: solid cursor bg, then redraw cell glyph in cursor-text color
            instances.append(.make(
                originX: x, originY: y, width: cw, height: ch,
                u0: 0, v0: 0, u1: 0, v1: 0,
                fr: tr, fg: tg, fb: tb, fa: 1,
                br: cr, bg: cg, bb: cb, ba: 1
            ))
            appendCursorCellGlyph(
                to: &instances,
                renderState: renderState,
                rowIter: rowIter,
                cells: cells,
                col: Int(cx),
                row: Int(cy),
                cellX: x,
                cellY: y,
                metrics: metrics,
                layout: layout,
                cellWInt: cellWInt,
                cellHInt: cellHInt,
                textR: tr, textG: tg, textB: tb
            )
        }
    }

    /// Redraw the character under a block cursor in cursor-text color (on top of fill).
    private func appendCursorCellGlyph(
        to instances: inout [CellInstance],
        renderState: GhosttyRenderState,
        rowIter: GhosttyRenderStateRowIterator,
        cells: GhosttyRenderStateRowCells,
        col: Int,
        row: Int,
        cellX: Float,
        cellY: Float,
        metrics: CellMetrics,
        layout: LayoutKey,
        cellWInt: Int,
        cellHInt: Int,
        textR: Float,
        textG: Float,
        textB: Float
    ) {
        guard col >= 0, row >= 0, col < layout.cols, row < layout.rows else { return }

        var iter = rowIter
        _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &iter)
        var r = 0
        while ghostty_render_state_row_iterator_next(iter) {
            defer { r += 1 }
            if r != row { continue }
            var cellsHandle = cells
            if ghostty_render_state_row_get(iter, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cellsHandle) != GHOSTTY_SUCCESS {
                return
            }
            var c = 0
            var skipTail = false
            while ghostty_render_state_row_cells_next(cellsHandle) {
                defer { c += 1 }
                if c != col {
                    // Still need to advance wide-tail state.
                    if skipTail {
                        skipTail = false
                        continue
                    }
                    var raw: GhosttyCell = 0
                    if ghostty_render_state_row_cells_get(
                        cellsHandle, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw
                    ) == GHOSTTY_SUCCESS {
                        var wide: GhosttyCellWide = GHOSTTY_CELL_WIDE_NARROW
                        if ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide) == GHOSTTY_SUCCESS,
                           wide == GHOSTTY_CELL_WIDE_WIDE {
                            skipTail = true
                        }
                    }
                    continue
                }
                if skipTail { return }

                var wideHead = false
                var raw: GhosttyCell = 0
                if ghostty_render_state_row_cells_get(
                    cellsHandle, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw
                ) == GHOSTTY_SUCCESS {
                    var wide: GhosttyCellWide = GHOSTTY_CELL_WIDE_NARROW
                    if ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide) == GHOSTTY_SUCCESS {
                        if wide == GHOSTTY_CELL_WIDE_SPACER_TAIL { return }
                        if wide == GHOSTTY_CELL_WIDE_WIDE { wideHead = true }
                    }
                }

                guard let text = cellTextUTF8(cellsHandle), !text.isEmpty else { return }

                var st = GhosttyStyle()
                st.size = MemoryLayout<GhosttyStyle>.size
                ghostty_style_default(&st)
                _ = ghostty_render_state_row_cells_get(
                    cellsHandle, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &st
                )
                let span = wideHead ? 2 : 1
                let entry: GlyphAtlas.Entry
                if let cp = text.unicodeScalars.first?.value,
                   text.unicodeScalars.count == 1,
                   SpriteFace.covers(cp) {
                    // Braille / box / blocks under the cursor — same sprite path.
                    entry = atlas.entrySprite(
                        codepoint: cp,
                        cellWidthPx: cellWInt * span,
                        cellHeightPx: cellHInt,
                        cellBaselinePx: metrics.cellBaselinePx
                    )
                } else {
                    let font = metrics.font(bold: st.bold, italic: st.italic)
                    entry = atlas.entry(
                        text: text,
                        bold: st.bold,
                        italic: st.italic,
                        font: font,
                        cellWidthPx: cellWInt * span,
                        cellHeightPx: cellHInt,
                        cellBaselinePx: metrics.cellBaselinePx,
                        faceWidthPx: metrics.faceWidthPx * CGFloat(span),
                        fallbackFonts: nerdFallbackFonts(metrics: metrics)
                    )
                }
                if entry.pixelW < 0.5 { return }
                // Full-cell text atlas entry (cursor-text): baseline-aligned inside the cell.
                instances.append(.make(
                    originX: cellX,
                    originY: cellY,
                    width: layout.cellW * Float(span),
                    height: layout.cellH,
                    u0: entry.uv.x, v0: entry.uv.y, u1: entry.uv.z, v1: entry.uv.w,
                    fr: textR, fg: textG, fb: textB, fa: 1,
                    br: 0, bg: 0, bb: 0, ba: 0
                ))
                return
            }
            return
        }
    }

    private func appendIndicator(
        to instances: inout [CellInstance],
        text: String,
        metrics: CellMetrics,
        layout: LayoutKey,
        cellWInt: Int,
        cellHInt: Int
    ) {
        var ix = layout.originX + layout.padPx + 4
        // Fixed in content rect (does not follow scroll).
        let iy = layout.originY + layout.padPx + 4
        let font = metrics.fontBold
        for ch in text {
            let entry = atlas.entry(
                text: String(ch),
                bold: true,
                italic: false,
                font: font,
                cellWidthPx: cellWInt,
                cellHeightPx: cellHInt,
                cellBaselinePx: metrics.cellBaselinePx,
                faceWidthPx: metrics.faceWidthPx
            )
            instances.append(.make(
                originX: ix, originY: iy, width: layout.cellW, height: layout.cellH,
                u0: entry.uv.x, v0: entry.uv.y, u1: entry.uv.z, v1: entry.uv.w,
                fr: 1, fg: 1, fb: 1, fa: 0.9,
                br: 0, bg: 0, bb: 0, ba: 0.4
            ))
            ix += layout.cellW
        }
    }

    // MARK: - GPU

    private func uploadInstances(_ instances: [CellInstance]) {
        // Merge underlines that were collected into underlineExtras already appended by caller.
        let count = instances.count
        ensureInstanceCapacity(max(count, 1))
        guard count > 0, let buf = instanceBuffer else {
            lastDrawnCount = 0
            return
        }
        let floatsNeeded = count * CellInstance.floatCount
        if floatScratch.count < floatsNeeded {
            floatScratch = [Float](repeating: 0, count: floatsNeeded)
        }
        floatScratch.withUnsafeMutableBufferPointer { dest in
            guard let base = dest.baseAddress else { return }
            for i in 0..<count {
                instances[i].write(to: base, at: i)
            }
            buf.contents().copyMemory(
                from: base,
                byteCount: floatsNeeded * MemoryLayout<Float>.size
            )
        }
    }

    private func present(
        count: Int,
        drawable: CAMetalDrawable,
        rpd: MTLRenderPassDescriptor,
        pw: Float,
        ph: Float,
        defBg: GhosttyColorRgb,
        clearColor: MTLClearColor
    ) {
        if let ub = uniformBuffer {
            var uni = FrameUniforms(viewportX: pw, viewportY: ph)
            withUnsafeBytes(of: &uni) { raw in
                ub.contents().copyMemory(from: raw.baseAddress!, byteCount: FrameUniforms.stride)
            }
        }

        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(defBg.r) / 255,
            green: Double(defBg.g) / 255,
            blue: Double(defBg.b) / 255,
            alpha: 1
        )
        rpd.colorAttachments[0].storeAction = .store

        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd)
        else { return }

        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(instanceBuffer, offset: 0, index: 0)
        enc.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
        enc.setFragmentTexture(atlas.texture, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)

        if count > 0 {
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: count)
        }

        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
        _ = clearColor
    }

    private func cellTextUTF8(_ cells: GhosttyRenderStateRowCells) -> String? {
        var storage = [UInt8](repeating: 0, count: 128)
        var written = 0
        let result = storage.withUnsafeMutableBufferPointer { buf -> GhosttyResult in
            var gb = GhosttyBuffer(ptr: buf.baseAddress, cap: buf.count, len: 0)
            let r = ghostty_render_state_row_cells_get(
                cells,
                GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8,
                &gb
            )
            if r == GHOSTTY_SUCCESS {
                written = Int(gb.len)
            }
            return r
        }
        if result == GHOSTTY_SUCCESS, written > 0 {
            return String(bytes: storage.prefix(written), encoding: .utf8)
        }

        var graphemeLen: UInt32 = 0
        _ = ghostty_render_state_row_cells_get(
            cells,
            GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN,
            &graphemeLen
        )
        guard graphemeLen > 0 else { return nil }
        var codepoints = [UInt32](repeating: 0, count: min(Int(graphemeLen), 16))
        codepoints.withUnsafeMutableBufferPointer { buf in
            _ = ghostty_render_state_row_cells_get(
                cells,
                GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF,
                buf.baseAddress
            )
        }
        let scalars = codepoints.prefix(Int(graphemeLen)).compactMap { UnicodeScalar($0) }
        let s = String(String.UnicodeScalarView(scalars))
        return s.isEmpty ? nil : s
    }

    private func ensureInstanceCapacity(_ count: Int) {
        if count <= instanceCapacity, instanceBuffer != nil { return }
        let cap = max(count * 2, 1024)
        instanceBuffer = device.makeBuffer(
            length: cap * CellInstance.stride,
            options: .storageModeShared
        )
        instanceCapacity = cap
    }

    private func presentClear(drawable: CAMetalDrawable, rpd: MTLRenderPassDescriptor, clearColor: MTLClearColor) {
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = clearColor
        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd)
        else { return }
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct CellInstance {
        float2 origin;
        float2 size;
        float4 uv;
        float4 fg;
        float4 bg;
    };

    struct FrameUniforms {
        float2 viewport;
        float2 _pad;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
        float4 fg;
        float4 bg;
        float hasGlyph;
    };

    constant float2 corners[6] = {
        float2(0, 0), float2(1, 0), float2(0, 1),
        float2(1, 0), float2(1, 1), float2(0, 1)
    };

    vertex VertexOut cell_vertex(uint vid [[vertex_id]],
                                 uint iid [[instance_id]],
                                 const device CellInstance *cells [[buffer(0)]],
                                 constant FrameUniforms &uni [[buffer(1)]]) {
        CellInstance c = cells[iid];
        float2 corner = corners[vid];
        float2 px = c.origin + corner * c.size;
        float2 ndc;
        ndc.x = (px.x / uni.viewport.x) * 2.0 - 1.0;
        ndc.y = 1.0 - (px.y / uni.viewport.y) * 2.0;
        VertexOut o;
        o.position = float4(ndc, 0.0, 1.0);
        o.uv = float2(mix(c.uv.x, c.uv.z, corner.x), mix(c.uv.y, c.uv.w, corner.y));
        o.fg = c.fg;
        o.bg = c.bg;
        o.hasGlyph = (c.uv.z > c.uv.x + 1e-6 && c.uv.w > c.uv.y + 1e-6) ? 1.0 : 0.0;
        return o;
    }

    fragment float4 cell_fragment(VertexOut in [[stage_in]],
                                  texture2d<float> atlas [[texture(0)]],
                                  sampler samp [[sampler(0)]]) {
        float4 bg = in.bg;
        float a = 0.0;
        if (in.hasGlyph > 0.5) {
            a = atlas.sample(samp, in.uv).r;
        }
        // Ink-only quads (multi-cell ligatures): transparent bg, blend glyph over prior cells.
        if (bg.a < 0.01) {
            if (a < 0.001) {
                return float4(0.0, 0.0, 0.0, 0.0);
            }
            return float4(in.fg.rgb, saturate(a));
        }
        if (bg.a < 0.99 && in.hasGlyph < 0.5) {
            return float4(bg.rgb * bg.a, bg.a);
        }
        float3 rgb = mix(bg.rgb, in.fg.rgb, saturate(a));
        return float4(rgb, 1.0);
    }
    """
}
