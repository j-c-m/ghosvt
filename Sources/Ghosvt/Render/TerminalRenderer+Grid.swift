import CGhosttyVT
import CoreText
import Foundation
import Metal

// MARK: - Grid rebuild + row paint
extension TerminalRenderer {
    /// Max paints if the glyph atlas resets mid-pass (invalidates earlier UVs).
    private static let atlasPaintAttempts = 3

    func rebuildAllRows(
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
        paintGridWithAtlasRetry(
            resetGridCells: true,
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

    func rebuildDirtyRows(
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
        // Ink is global in glyphExtras — always repaint every row.
        paintGridWithAtlasRetry(
            resetGridCells: false,
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

    /// Clears ink extras and repaints; retries if `atlas.packGeneration` changes mid-pass.
    private func paintGridWithAtlasRetry(
        resetGridCells: Bool,
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
        for _ in 0..<Self.atlasPaintAttempts {
            let gen = atlas.packGeneration
            if resetGridCells {
                gridCells = Array(
                    repeating: CellInstance.make(
                        originX: 0, originY: 0, width: layout.cellW, height: layout.cellH,
                        u0: 0, v0: 0, u1: 0, v1: 0,
                        fr: 0, fg: 0, fb: 0, fa: 1,
                        br: Float(defBg.r) / 255, bg: Float(defBg.g) / 255, bb: Float(defBg.b) / 255, ba: 1
                    ),
                    count: layout.cols * layout.rows
                )
            }
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
                cellHInt: cellHInt
            )
            if atlas.packGeneration == gen { break }
        }
    }

    func rebuildRows(
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
        let genAtStart = atlas.packGeneration
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
            let base = rowIndex * layout.cols
            if rowCellCache.count < layout.cols * layout.rows {
                rowCellCache = Array(
                    repeating: TerminalRowCell(
                        text: "", isWideHead: false, isWideTail: false,
                        fg: defFg, bg: defBg,
                        bold: false, italic: false, faint: false, inverse: false, underline: false
                    ),
                    count: layout.cols * layout.rows
                )
            }
            for (c, cell) in rowCells.enumerated() where c < layout.cols {
                rowCellCache[base + c] = cell
            }
            paintRow(
                rowCells: rowCells,
                rowIndex: rowIndex,
                metrics: metrics,
                layout: layout,
                defBg: defBg,
                cellWInt: cellWInt,
                cellHInt: cellHInt,
                renderState: renderState,
                rowIter: iter
            )

            var clean = false
            _ = ghostty_render_state_row_set(iter, GHOSTTY_RENDER_STATE_ROW_OPTION_DIRTY, &clean)

            if atlas.packGeneration != genAtStart { break }
        }
    }

    // MARK: - Run segmentation + shaped paint

    func collectRowCells(
        cellsHandle: GhosttyRenderStateRowCells,
        layout: LayoutKey,
        defFg: GhosttyColorRgb,
        defBg: GhosttyColorRgb
    ) -> [TerminalRowCell] {
        var out: [TerminalRowCell] = []
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
            // Kitty virtual placeholder: never draw the U+10EEEE glyph (Ghostty blanks it).
            var text = cellTextUTF8(cellsHandle) ?? ""
            var cp: UInt32 = 0
            if let first = text.unicodeScalars.first {
                if first.value == KittyVirtualUnicode.placeholder {
                    text = ""
                } else {
                    cp = first.value
                }
            }

            out.append(TerminalRowCell(
                text: text,
                cp: cp,
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
            out.append(TerminalRowCell(
                text: "", isWideHead: false, isWideTail: false,
                fg: defFg, bg: defBg,
                bold: false, italic: false, faint: false, inverse: false, underline: false
            ))
        }
        return out
    }

    func paintRow(
        rowCells: [TerminalRowCell],
        rowIndex: Int,
        metrics: CellMetrics,
        layout: LayoutKey,
        defBg: GhosttyColorRgb,
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

        // Search highlights for this viewport row (screen coords already mapped).
        let rowSearch = searchHighlights.filter { $0.row == rowIndex }

        func highlight(for col: Int) -> CellPaintColors.Highlight {
            // Ghostty precedence: mouse selection > current search match > other matches.
            if let s = selStart, let e = selEnd {
                let lo = min(s, e), hi = max(s, e)
                if col >= lo && col <= hi { return .selection }
            }
            var kind: CellPaintColors.Highlight = .none
            for h in rowSearch {
                if col >= h.startX && col <= h.endX {
                    if h.isCurrent { return .searchSelected }
                    kind = .search
                }
            }
            return kind
        }

        func selected(_ col: Int) -> Bool {
            highlight(for: col) != .none
        }

        // 1) Background for every cell (selection invert / search gold / current peach).
        // Default terminal bg is transparent (ba=0) so Kitty below_bg shows through the
        // letterbox/clear color; only non-default or highlighted cells cover images.
        let defBr = Float(defBg.r) / 255
        let defBgG = Float(defBg.g) / 255
        let defBb = Float(defBg.b) / 255
        for col in 0..<layout.cols {
            let c = rowCells[col]
            let x = (layout.originX + layout.padPx + Float(col) * layout.cellW)
                .rounded(.toNearestOrAwayFromZero)
            let yPx = y
            let hl = highlight(for: col)
            let colors = CellPaintColors.pair(
                fg: c.fg, bg: c.bg, faint: c.faint, highlight: hl
            )
            let fr = colors.ink.r, fgG = colors.ink.g, fb = colors.ink.b
            let br = colors.fill.r, bgG = colors.fill.g, bb = colors.fill.b
            let isDefaultBg = hl == .none
                && abs(br - defBr) < 1e-4
                && abs(bgG - defBgG) < 1e-4
                && abs(bb - defBb) < 1e-4
            let ba: Float = isDefaultBg ? 0 : 1
            let idx = rowIndex * layout.cols + col
            if idx < gridCells.count {
                gridCells[idx] = CellInstance.make(
                    originX: x, originY: yPx,
                    width: layout.cellW, height: layout.cellH,
                    u0: 0, v0: 0, u1: 0, v1: 0,
                    fr: fr, fg: fgG, fb: fb, fa: 1,
                    br: br, bg: bgG, bb: bb, ba: ba
                )
            }
            if c.underline {
                // Font underline metrics (same path as ⌘-hover links).
                let th = Float(max(1, metrics.underlineThicknessPx))
                let uy = y + Float(metrics.underlineTopPx)
                underlineExtras.append(.make(
                    originX: x, originY: uy,
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
        // Break runs at selection and search boundaries so highlight ink stays cell-local.
        var breakCols: [Int] = []
        if let s = selStart, let e = selEnd {
            breakCols.append(min(s, e))
            breakCols.append(max(s, e) + 1)
        }
        for h in rowSearch {
            breakCols.append(h.startX)
            breakCols.append(h.endX + 1)
        }
        let segments = segmentRuns(
            rowCells,
            selectionLo: nil,
            selectionHi: nil,
            highlightBreaks: breakCols,
            cursorCol: cursorCol
        )
        for seg in segments {
            switch seg {
            case .wide(let col):
                paintWideOrFallback(
                    col: col, rowIndex: rowIndex, rowCells: rowCells,
                    metrics: metrics, layout: layout,
                    cellWInt: cellWInt, cellHInt: cellHInt,
                    highlight: highlight(for: col)
                )
            case .run(let start, let end, let style, let contentHash):
                paintShapedRun(
                    start: start, end: end, style: style,
                    contentHash: contentHash,
                    rowCells: rowCells, rowIndex: rowIndex,
                    metrics: metrics, layout: layout,
                    cellWInt: cellWInt, cellHInt: cellHInt,
                    selected: selected
                )
            }
        }
    }

    enum RunSeg {
        case run(start: Int, end: Int, style: TextStyleKey, contentHash: UInt64)
        case wide(col: Int)
    }

    /// Segment a row into shape runs (Ghostty `RunIterator`).
    ///
    /// Breaks on: text style (not bg), wide heads, selection / search
    /// boundaries, cursor column, and Ghostty bad ligatures (`fi`/`fl`/`st`).
    /// Spaces and empty cells stay in the run. Trailing empty cells are trimmed.
    func segmentRuns(
        _ cells: [TerminalRowCell],
        selectionLo: Int?,
        selectionHi: Int?,
        highlightBreaks: [Int] = [],
        cursorCol: Int?
    ) -> [RunSeg] {
        var segs: [RunSeg] = []
        var i = 0
        var runStart: Int?
        var runStyle: TextStyleKey?
        var runHash = ShaperCache.fnvOffset
        let breakSet = Set(highlightBreaks)

        // Ghostty: trim the right edge of empty cells before forming runs.
        var maxCol = cells.count
        while maxCol > 0 {
            let c = cells[maxCol - 1]
            if !c.isWideTail, c.cp != 0 || !c.text.isEmpty { break }
            maxCol -= 1
        }

        func beginRun(at col: Int, style: TextStyleKey, cp: UInt32) {
            runStart = col
            runStyle = style
            runHash = ShaperCache.fnvOffset
            ShaperCache.mixCell(&runHash, cp: cp, cluster: 0)
        }

        func flushRun(upTo end: Int) {
            guard let s = runStart, let st = runStyle, s < end else {
                runStart = nil
                runStyle = nil
                return
            }
            ShaperCache.mix(&runHash, UInt64(end - s))
            segs.append(.run(start: s, end: end, style: st, contentHash: runHash))
            runStart = nil
            runStyle = nil
        }

        /// True if we must end the current run before absorbing column `i`.
        func mustBreakBefore(i: Int, runStart: Int) -> Bool {
            if i <= runStart { return false }

            // Selection / search: break at enter (lo) and leave (hi+1). Inclusive hi.
            if let lo = selectionLo, let hi = selectionHi {
                if i == lo { return true }
                if i == hi + 1 { return true }
            }
            if breakSet.contains(i) { return true }

            // Cursor: run before cursor stops at cursor; cursor cell is its own run.
            if let cx = cursorCol {
                if runStart < cx, i == cx { return true }
                if runStart == cx, i == runStart + 1 { return true }
            }

            if Self.isBadLigaturePair(prev: cells[i - 1], next: cells[i]) {
                return true
            }

            return false
        }

        while i < maxCol {
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

            if let s = runStart, mustBreakBefore(i: i, runStart: s) {
                flushRun(upTo: i)
            }

            let st = c.textStyle
            if runStart == nil {
                beginRun(at: i, style: st, cp: c.cp)
            } else if st != runStyle {
                flushRun(upTo: i)
                beginRun(at: i, style: st, cp: c.cp)
            } else if let s = runStart {
                ShaperCache.mixCell(&runHash, cp: c.cp, cluster: i - s)
            }
            i += 1
        }
        flushRun(upTo: maxCol)
        return segs
    }

    /// Ghostty: split `fi` / `fl` / `st` (plain lowercase codepoints only).
    private static func isBadLigaturePair(prev: TerminalRowCell, next: TerminalRowCell) -> Bool {
        switch prev.cp {
        case 0x66 where next.cp == 0x69 || next.cp == 0x6C:
            return true
        case 0x73 where next.cp == 0x74:
            return true
        default:
            return false
        }
    }

    func paintShapedRun(
        start: Int,
        end: Int,
        style: TextStyleKey,
        contentHash: UInt64,
        rowCells: [TerminalRowCell],
        rowIndex: Int,
        metrics: CellMetrics,
        layout: LayoutKey,
        cellWInt: Int,
        cellHInt: Int,
        selected: (Int) -> Bool
    ) {
        guard start < end else { return }

        let font = metrics.font(bold: style.bold, italic: style.italic)
        let shapedFont = shaper.featuredFont(font, ligatures: fontLigatures)
        let nerdFaces = EmbeddedFonts.nerdFaces(size: CTFontGetSize(metrics.font))

        // Ligatures only when every cell is a normal primary-face glyph.
        // ASCII/empty is the primary face — no Core Text coverage walk.
        let allPrimary = rowCells.withUnsafeBufferPointer { buf -> Bool in
            var col = start
            while col < end {
                let cp = buf[col].cp
                if cp == 0 || (cp >= 0x20 && cp <= 0x7E) {
                    col += 1
                    continue
                }
                let t = buf[col].text
                if SpriteFace.covers(text: t) { return false }
                if GlyphAtlas.isPrivateUse(t) { return false }
                if !GlyphAtlas.fontCovers(shapedFont, text: t) { return false }
                col += 1
            }
            return true
        }

        if allPrimary {
            paintLigatureRun(
                start: start, end: end, style: style, contentHash: contentHash,
                rowCells: rowCells, rowIndex: rowIndex, metrics: metrics, layout: layout,
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
    func paintLigatureRun(
        start: Int,
        end: Int,
        style: TextStyleKey,
        contentHash: UInt64,
        rowCells: [TerminalRowCell],
        rowIndex: Int,
        metrics: CellMetrics,
        layout: LayoutKey,
        cellWInt: Int,
        cellHInt: Int,
        selected: (Int) -> Bool,
        shapedFont: CTFont
    ) {
        let placements = shaper.shape(
            cells: rowCells,
            start: start,
            end: end,
            contentHash: contentHash,
            font: shapedFont,
            fontPx: layout.fontPx,
            ligatures: fontLigatures,
            bold: style.bold,
            italic: style.italic
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
    func paintCellsIndividually(
        start: Int,
        end: Int,
        style: TextStyleKey,
        rowCells: [TerminalRowCell],
        rowIndex: Int,
        metrics: CellMetrics,
        layout: LayoutKey,
        cellWInt: Int,
        cellHInt: Int,
        selected: (Int) -> Bool,
        primary: CTFont,
        nerdFaces: [CTFont]
    ) {
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

    func appendGlyphExtra(
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
        // Ghostty: grid origin is integer; bearings/x_offset are whole pixels.
        // Do not re-round the sum (that shifts ink vs Ghostty by up to 1 px).
        let cellX = (layout.originX + layout.padPx + Float(col) * layout.cellW)
            .rounded(.towardZero)
        let ox = cellX + xOffset + entry.bearingX
        let oy = rowTop + entry.bearingY - yOffset
        let pwG = entry.pixelW
        let phG = entry.pixelH

        // Prefer gridCells ink (post selection / search highlight) over style colors.
        var ifr = fr, ifg = fg, ifb = fb
        let idx = rowIndex * layout.cols + col
        if idx < gridCells.count {
            let cell = gridCells[idx]
            ifr = cell.fr; ifg = cell.fg; ifb = cell.fb
        }
        _ = selected

        glyphExtras.append(.make(
            originX: ox, originY: oy,
            width: max(1, pwG), height: max(1, phG),
            u0: entry.uv.x, v0: entry.uv.y, u1: entry.uv.z, v1: entry.uv.w,
            fr: ifr, fg: ifg, fb: ifb, fa: 1,
            br: 0, bg: 0, bb: 0, ba: 0
        ))
    }

    /// Best face + single glyph: primary / Nerd, then Ghostty-style system discovery.
    func resolveGlyphFace(
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
        // Same as Ghostty CodepointResolver: CTFontCreateForString cascade
        // (e.g. U+26E8 ⛨ → STIXTwoMath-Regular).
        if let sys = SystemFontFallback.face(for: text, from: primary),
           let glyphs = GlyphAtlas.glyphs(for: text, font: sys),
           glyphs.count == 1 {
            return (sys, glyphs[0])
        }
        return nil
    }

    func nerdFallbackFonts(metrics: CellMetrics) -> [CTFont] {
        EmbeddedFonts.nerdFaces(size: CTFontGetSize(metrics.font))
    }

    func paintWideOrFallback(
        col: Int,
        rowIndex: Int,
        rowCells: [TerminalRowCell],
        metrics: CellMetrics,
        layout: LayoutKey,
        cellWInt: Int,
        cellHInt: Int,
        highlight: CellPaintColors.Highlight
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
        // Cell bg stays in gridCells (step 1). Ink goes to glyphExtras so below_text
        // Kitty images sit under wide glyphs (same order as shaped runs).
        let cellX = (layout.originX + layout.padPx + Float(col) * layout.cellW)
            .rounded(.towardZero)
        let rowTop = (layout.originY + layout.padPx + Float(rowIndex) * layout.cellH)
            .rounded(.toNearestOrAwayFromZero)
        var ifr = Float(c.fg.r) / 255
        var ifg = Float(c.fg.g) / 255
        var ifb = Float(c.fg.b) / 255
        let colors = CellPaintColors.pair(fg: c.fg, bg: c.bg, faint: c.faint, highlight: highlight)
        ifr = colors.ink.r
        ifg = colors.ink.g
        ifb = colors.ink.b
        let idx = rowIndex * layout.cols + col
        if idx < gridCells.count {
            let cell = gridCells[idx]
            ifr = cell.fr; ifg = cell.fg; ifb = cell.fb
        }
        glyphExtras.append(.make(
            originX: cellX + entry.bearingX,
            originY: rowTop + entry.bearingY,
            width: max(1, entry.pixelW),
            height: max(1, entry.pixelH),
            u0: entry.uv.x, v0: entry.uv.y, u1: entry.uv.z, v1: entry.uv.w,
            fr: ifr, fg: ifg, fb: ifb, fa: 1,
            br: 0, bg: 0, bb: 0, ba: 0
        ))
    }


}
