import CGhosttyVT
import CoreText
import Foundation
import Metal

// MARK: - Grid rebuild + row paint
extension TerminalRenderer {
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

    func rebuildRows(
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
            // Cache full row for cursor under-glyph.
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
        }
        _ = onlyDirty
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
            if text.unicodeScalars.first?.value == KittyVirtualUnicode.placeholder {
                text = ""
            }

            out.append(TerminalRowCell(
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
            case .gap:
                break
            case .wide(let col):
                paintWideOrFallback(
                    col: col, rowIndex: rowIndex, rowCells: rowCells,
                    metrics: metrics, layout: layout,
                    cellWInt: cellWInt, cellHInt: cellHInt,
                    highlight: highlight(for: col)
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

    enum RunSeg {
        case run(start: Int, end: Int, style: TextStyleKey) // end exclusive
        case wide(col: Int)
        case gap
    }

    /// Segment a row into shape runs (Ghostty-aligned break rules).
    ///
    /// Breaks on: 2+ spaces/empties, text style (not bg), wide cells,
    /// selection / search boundaries, cursor column, and bad ligatures (fi/fl/st).
    /// Single spaces stay inside runs; 2+ spaces are gaps.
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
        let breakSet = Set(highlightBreaks)

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

            // Selection / search: break at enter (lo) and leave (hi+1). Inclusive hi.
            if let lo = selectionLo, let hi = selectionHi {
                if i == lo { return true }
                if i == hi + 1 { return true }
            }
            if breakSet.contains(i) { return true }

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
    private static func isBadLigaturePair(prev: TerminalRowCell, next: TerminalRowCell) -> Bool {
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

    func paintShapedRun(
        start: Int,
        end: Int,
        style: TextStyleKey,
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
    func paintLigatureRun(
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

    /// Best face + single glyph for a cell: Nerd for PUA / missing primary, else primary.
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
