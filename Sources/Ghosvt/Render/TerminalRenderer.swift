import CGhosttyVT
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
    private var instanceBuffer: MTLBuffer?
    private var uniformBuffer: MTLBuffer?
    private var instanceCapacity = 0
    private var floatScratch = [Float]()

    private let padPoints: CGFloat

    // MARK: Grid cache
    private var gridCells: [CellInstance] = []
    private var gridCols = 0
    private var gridRows = 0
    private var lastDrawnCount = 0
    private var lastLayoutKey: LayoutKey?
    private var lastDefBg = (r: UInt8(12), g: UInt8(12), b: UInt8(16))
    private var lastIndicator: String?
    private var lastBlinkOn = true
    private var lastVisualY: Float = 0
    private var blinkPeriod: CFTimeInterval = 0.53
    private var prewarmedKey: String?

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
        visualOffsetRows: Double = 0
    ) {
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

        let originX = Float(contentRect.minX)
        let originY = Float(contentRect.minY)
        let cellW = Float(metrics.cellWidth * scale)
        let cellH = Float(metrics.cellHeight * scale)
        let padPx = Float(padPoints * scale)
        let cellWInt = max(1, Int(cellW.rounded(.toNearestOrAwayFromZero)))
        let cellHInt = max(1, Int(cellH.rounded(.toNearestOrAwayFromZero)))
        // Fractional / overscroll shift in drawable pixels (top-left coords).
        let visualY = Float(visualOffsetRows) * cellH

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
            cols: cols, rows: rows, fontPx: cellHInt
        )

        // Prewarm ASCII once per font pixel size.
        let warmKey = "\(cellWInt)x\(cellHInt)"
        if prewarmedKey != warmKey {
            atlas.prewarmASCII(
                font: metrics.font,
                boldFont: metrics.fontBold,
                cellWidthPx: cellWInt,
                cellHeightPx: cellHInt
            )
            prewarmedKey = warmKey
        }

        var colors = GhosttyRenderStateColors()
        colors.size = MemoryLayout<GhosttyRenderStateColors>.size
        _ = ghostty_render_state_colors_get(renderState, &colors)

        var defFg = colors.foreground
        var defBg = colors.background
        if defFg.r == 0, defFg.g == 0, defFg.b == 0,
           defBg.r == 0, defBg.g == 0, defBg.b == 0 {
            defFg.r = 230; defFg.g = 230; defFg.b = 230
            defBg.r = 12; defBg.g = 12; defBg.b = 16
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

        let needGridRebuild: Bool
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

        if needGridRebuild {
            if partialOnly {
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

        // Idle: reuse previous GPU buffer (includes last cursor/indicator).
        // Keep recomposing while fractional / overscroll offset is moving.
        if !needGridRebuild && !blinkChanged && !indicatorChanged && !visualChanged && lastDrawnCount > 0 {
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
        instances.append(contentsOf: underlineExtras)
        if abs(visualY) > 0.001 {
            for i in 0..<instances.count {
                instances[i].oy += visualY
            }
        }

        appendCursor(
            to: &instances,
            renderState: renderState,
            colors: colors,
            defFg: defFg,
            layout: layout,
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
        // Partial path: drop previous underline extras for dirty rows by full underline rebuild.
        underlineExtras = []
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
            onlyDirty: true
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

            var isDirty = true
            if onlyDirty {
                var d = false
                _ = ghostty_render_state_row_get(iter, GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY, &d)
                isDirty = d
                if !isDirty {
                    // Still collect underlines for clean rows from existing? Skip — underlines
                    // only on rebuild of that row. For clean rows underlines already missing
                    // unless we store them in grid. Re-scan clean rows for underline only once:
                    // simpler to force full underline pass over all rows each dirty frame.
                }
            }

            var cellsHandle = cells
            if ghostty_render_state_row_get(iter, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cellsHandle) != GHOSTTY_SUCCESS {
                continue
            }

            let y = layout.originY + layout.padPx + Float(rowIndex) * layout.cellH
            var colIndex = 0
            var skipTail = false

            while ghostty_render_state_row_cells_next(cellsHandle) {
                defer { colIndex += 1 }
                guard colIndex < layout.cols else { break }

                if skipTail {
                    // Wide spacer tail: bg only if dirty
                    skipTail = false
                    if onlyDirty && !isDirty { continue }
                    let x = layout.originX + layout.padPx + Float(colIndex) * layout.cellW
                    // Copy bg from previous cell if possible
                    let idx = rowIndex * layout.cols + colIndex
                    if idx > 0, idx < gridCells.count {
                        var tail = gridCells[idx - 1]
                        tail.ox = x
                        tail.oy = y
                        tail.u0 = 0; tail.v0 = 0; tail.u1 = 0; tail.v1 = 0
                        gridCells[idx] = tail
                    }
                    continue
                }

                // Wide check via raw cell
                var rawCell: GhosttyCell = 0
                if ghostty_render_state_row_cells_get(
                    cellsHandle,
                    GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW,
                    &rawCell
                ) == GHOSTTY_SUCCESS {
                    var wide: GhosttyCellWide = GHOSTTY_CELL_WIDE_NARROW
                    if ghostty_cell_get(rawCell, GHOSTTY_CELL_DATA_WIDE, &wide) == GHOSTTY_SUCCESS {
                        if wide == GHOSTTY_CELL_WIDE_SPACER_TAIL {
                            if onlyDirty && !isDirty { continue }
                            let x = layout.originX + layout.padPx + Float(colIndex) * layout.cellW
                            let idx = rowIndex * layout.cols + colIndex
                            if idx < gridCells.count {
                                var c = gridCells[idx]
                                c.ox = x; c.oy = y
                                c.sx = layout.cellW; c.sy = layout.cellH
                                c.u0 = 0; c.v0 = 0; c.u1 = 0; c.v1 = 0
                                gridCells[idx] = c
                            }
                            continue
                        }
                        if wide == GHOSTTY_CELL_WIDE_WIDE {
                            skipTail = true
                        }
                    }
                }

                if onlyDirty && !isDirty {
                    // Still need underlines for this row on partial frames — scan style
                    appendUnderlineIfNeeded(
                        cellsHandle: cellsHandle,
                        row: rowIndex, col: colIndex,
                        layout: layout, defFg: defFg, defBg: defBg
                    )
                    continue
                }

                let x = layout.originX + layout.padPx + Float(colIndex) * layout.cellW
                let inst = makeCellInstance(
                    cellsHandle: cellsHandle,
                    x: x, y: y,
                    layout: layout,
                    metrics: metrics,
                    defFg: defFg,
                    defBg: defBg,
                    cellWInt: cellWInt,
                    cellHInt: cellHInt,
                    wide: skipTail
                )
                let idx = rowIndex * layout.cols + colIndex
                if idx < gridCells.count {
                    gridCells[idx] = inst.cell
                }
                if let ul = inst.underline {
                    underlineExtras.append(ul)
                }

                var clean = false
                _ = ghostty_render_state_row_set(iter, GHOSTTY_RENDER_STATE_ROW_OPTION_DIRTY, &clean)
            }
        }

        // On partial dirty, rebuild ALL underlines from cache by re-walking (cheap vs glyphs).
        if onlyDirty {
            underlineExtras = []
            rebuildAllUnderlines(
                renderState: renderState,
                rowIter: rowIter,
                cells: cells,
                layout: layout,
                defFg: defFg,
                defBg: defBg
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
            let entry = atlas.entry(
                text: str,
                bold: style.bold,
                italic: style.italic,
                font: font,
                cellWidthPx: wide ? cellWInt * 2 : cellWInt,
                cellHeightPx: cellHInt,
                fallbackFonts: [
                    EmbeddedFonts.primaryNerdMono(size: CGFloat(cellHInt) * 0.85),
                    EmbeddedFonts.primaryNerd(size: CGFloat(cellHInt) * 0.85),
                ]
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
        colors: GhosttyRenderStateColors,
        defFg: GhosttyColorRgb,
        layout: LayoutKey,
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

        var cur = defFg
        if colors.cursor_has_value { cur = colors.cursor }
        let cr = Float(cur.r) / 255
        let cg = Float(cur.g) / 255
        let cb = Float(cur.b) / 255
        let x = layout.originX + layout.padPx + Float(cx) * layout.cellW
        let y = layout.originY + layout.padPx + Float(cy) * layout.cellH + visualY
        let cw = layout.cellW
        let ch = layout.cellH

        switch style {
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR:
            let w = max(2, cw * 0.12)
            instances.append(.make(
                originX: x, originY: y, width: w, height: ch,
                u0: 0, v0: 0, u1: 0, v1: 0,
                fr: cr, fg: cg, fb: cb, fa: 0.9,
                br: cr, bg: cg, bb: cb, ba: 0.9
            ))
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE:
            let h = max(2, ch * 0.12)
            instances.append(.make(
                originX: x, originY: y + ch - h, width: cw, height: h,
                u0: 0, v0: 0, u1: 0, v1: 0,
                fr: cr, fg: cg, fb: cb, fa: 0.9,
                br: cr, bg: cg, bb: cb, ba: 0.9
            ))
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW:
            let t: Float = max(1, min(cw, ch) * 0.08)
            // top, bottom, left, right edges
            instances.append(.make(originX: x, originY: y, width: cw, height: t, u0: 0, v0: 0, u1: 0, v1: 0, fr: cr, fg: cg, fb: cb, fa: 0.9, br: cr, bg: cg, bb: cb, ba: 0.9))
            instances.append(.make(originX: x, originY: y + ch - t, width: cw, height: t, u0: 0, v0: 0, u1: 0, v1: 0, fr: cr, fg: cg, fb: cb, fa: 0.9, br: cr, bg: cg, bb: cb, ba: 0.9))
            instances.append(.make(originX: x, originY: y, width: t, height: ch, u0: 0, v0: 0, u1: 0, v1: 0, fr: cr, fg: cg, fb: cb, fa: 0.9, br: cr, bg: cg, bb: cb, ba: 0.9))
            instances.append(.make(originX: x + cw - t, originY: y, width: t, height: ch, u0: 0, v0: 0, u1: 0, v1: 0, fr: cr, fg: cg, fb: cb, fa: 0.9, br: cr, bg: cg, bb: cb, ba: 0.9))
        default: // block
            instances.append(.make(
                originX: x, originY: y, width: cw, height: ch,
                u0: 0, v0: 0, u1: 0, v1: 0,
                fr: cr, fg: cg, fb: cb, fa: 0.55,
                br: cr, bg: cg, bb: cb, ba: 0.55
            ))
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
                cellHeightPx: cellHInt
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
        if (bg.a < 0.99 && in.hasGlyph < 0.5) {
            return float4(bg.rgb * bg.a, bg.a);
        }
        float a = 0.0;
        if (in.hasGlyph > 0.5) {
            a = atlas.sample(samp, in.uv).r;
        }
        float3 rgb = mix(bg.rgb, in.fg.rgb, saturate(a));
        return float4(rgb, 1.0);
    }
    """
}
