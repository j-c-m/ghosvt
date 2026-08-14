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
        paintGridWithAtlasRetry(
            dirtyOnly: false,
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
        paintGridWithAtlasRetry(
            dirtyOnly: true,
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

    /// Repaint dirty (or all) rows; retry the full grid if the atlas resets mid-pass.
    private func paintGridWithAtlasRetry(
        dirtyOnly: Bool,
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
        for attempt in 0..<Self.atlasPaintAttempts {
            let gen = atlas.packGeneration
            // Atlas eviction invalidates UVs already stored on clean rows.
            let skipClean = dirtyOnly && attempt == 0
            preparePaintFonts(metrics: metrics)
            ensureGridLayers(layout: layout, defFg: defFg, defBg: defBg)
            rebuildRows(
                dirtyOnly: skipClean,
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
            flattenInkExtras()
            if atlas.packGeneration == gen { break }
        }
    }

    func ensureGridLayers(layout: LayoutKey, defFg: GhosttyColorRgb, defBg: GhosttyColorRgb) {
        gridCols = layout.cols
        gridRows = layout.rows
        let n = layout.cols * layout.rows
        if gridCells.count != n {
            gridCells = Array(
                repeating: CellInstance.make(
                    originX: 0, originY: 0, width: layout.cellW, height: layout.cellH,
                    u0: 0, v0: 0, u1: 0, v1: 0,
                    fr: 0, fg: 0, fb: 0, fa: 1,
                    br: Float(defBg.r) / 255, bg: Float(defBg.g) / 255, bb: Float(defBg.b) / 255, ba: 1
                ),
                count: n
            )
        }
        if rowCellCache.count != n {
            rowCellCache = Array(
                repeating: TerminalRowCell(
                    text: "", isWideHead: false, isWideTail: false,
                    fg: defFg, bg: defBg,
                    bold: false, italic: false, faint: false, inverse: false, underline: false
                ),
                count: n
            )
        }
        if glyphExtrasByRow.count != layout.rows {
            glyphExtrasByRow = Array(repeating: [], count: layout.rows)
            underlineExtrasByRow = Array(repeating: [], count: layout.rows)
        }
    }

    func flattenInkExtras() {
        var glyphN = 0
        var ulN = 0
        for i in 0..<glyphExtrasByRow.count {
            glyphN += glyphExtrasByRow[i].count
            ulN += underlineExtrasByRow[i].count
        }
        glyphExtras.removeAll(keepingCapacity: true)
        underlineExtras.removeAll(keepingCapacity: true)
        glyphExtras.reserveCapacity(glyphN)
        underlineExtras.reserveCapacity(ulN)
        for i in 0..<glyphExtrasByRow.count {
            glyphExtras.append(contentsOf: glyphExtrasByRow[i])
            underlineExtras.append(contentsOf: underlineExtrasByRow[i])
        }
    }

    func rebuildRows(
        dirtyOnly: Bool,
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

        var cursorInViewport = false
        var curX: UInt16 = 0
        var curY: UInt16 = 0
        _ = ghostty_render_state_get(
            renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE, &cursorInViewport
        )
        if cursorInViewport {
            _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X, &curX)
            _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y, &curY)
        }

        var rowIndex = 0
        while ghostty_render_state_row_iterator_next(iter) {
            defer { rowIndex += 1 }
            guard rowIndex < layout.rows else { break }

            if dirtyOnly {
                var isDirty = false
                _ = ghostty_render_state_row_get(
                    iter, GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY, &isDirty
                )
                if !isDirty { continue }
            }

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
            let n = min(rowCells.count, layout.cols)
            if n > 0, base + n <= rowCellCache.count {
                rowCellCache.replaceSubrange(base..<(base + n), with: rowCells[0..<n])
            }
            let rowCursor: Int? = (cursorInViewport && Int(curY) == rowIndex) ? Int(curX) : nil
            paintRow(
                rowCells: rowCells,
                rowIndex: rowIndex,
                metrics: metrics,
                layout: layout,
                defBg: defBg,
                cellWInt: cellWInt,
                cellHInt: cellHInt,
                rowIter: iter,
                cursorCol: rowCursor
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
        let empty = TerminalRowCell(
            text: "", isWideHead: false, isWideTail: false,
            fg: defFg, bg: defBg,
            bold: false, italic: false, faint: false, inverse: false, underline: false
        )
        if collectScratch.count != layout.cols {
            collectScratch = Array(repeating: empty, count: layout.cols)
        }

        var skipTail = false
        var col = 0
        while ghostty_render_state_row_cells_next(cellsHandle) {
            defer { col += 1 }
            guard col < layout.cols else { break }

            var rawCell: GhosttyCell = 0
            let hasRaw = ghostty_render_state_row_cells_get(
                cellsHandle,
                GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW,
                &rawCell
            ) == GHOSTTY_SUCCESS

            var isWideHead = false
            var isWideTail = false
            var hasText = false
            var hasStyling = false
            var contentTag = GHOSTTY_CELL_CONTENT_CODEPOINT
            if skipTail {
                isWideTail = true
                skipTail = false
            }
            if hasRaw {
                if !isWideTail {
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
                _ = ghostty_cell_get(rawCell, GHOSTTY_CELL_DATA_HAS_TEXT, &hasText)
                _ = ghostty_cell_get(rawCell, GHOSTTY_CELL_DATA_HAS_STYLING, &hasStyling)
                _ = ghostty_cell_get(rawCell, GHOSTTY_CELL_DATA_CONTENT_TAG, &contentTag)
            }

            let bgOnly =
                contentTag == GHOSTTY_CELL_CONTENT_BG_COLOR_PALETTE
                || contentTag == GHOSTTY_CELL_CONTENT_BG_COLOR_RGB

            var fg = defFg
            var bgCell = defBg
            var hasBg = false
            var bold = false
            var italic = false
            var faint = false
            var inverse = false
            var underline = false
            if hasStyling || bgOnly {
                _ = ghostty_render_state_row_cells_get(
                    cellsHandle, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &fg
                )
                hasBg = ghostty_render_state_row_cells_get(
                    cellsHandle, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &bgCell
                ) == GHOSTTY_SUCCESS
                var style = GhosttyStyle()
                style.size = MemoryLayout<GhosttyStyle>.size
                ghostty_style_default(&style)
                _ = ghostty_render_state_row_cells_get(
                    cellsHandle, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style
                )
                bold = style.bold
                italic = style.italic
                faint = style.faint
                inverse = style.inverse
                underline = style.underline != 0
                if inverse {
                    swap(&fg, &bgCell)
                }
            }
            let bg = (hasBg || inverse) ? bgCell : defBg

            var text = ""
            var cp: UInt32 = 0
            if hasText {
                let packed = packedCellText(cellsHandle, raw: hasRaw ? rawCell : nil)
                text = packed.text
                cp = packed.cp
            }

            collectScratch[col] = TerminalRowCell(
                text: text,
                cp: cp,
                isWideHead: isWideHead,
                isWideTail: isWideTail,
                fg: fg,
                bg: bg,
                bold: bold,
                italic: italic,
                faint: faint,
                inverse: inverse,
                underline: underline
            )
        }
        while col < layout.cols {
            collectScratch[col] = empty
            col += 1
        }
        return collectScratch
    }

    func paintRow(
        rowCells: [TerminalRowCell],
        rowIndex: Int,
        metrics: CellMetrics,
        layout: LayoutKey,
        defBg: GhosttyColorRgb,
        cellWInt: Int,
        cellHInt: Int,
        rowIter: GhosttyRenderStateRowIterator,
        cursorCol: Int?
    ) {
        if rowIndex < glyphExtrasByRow.count {
            glyphExtrasByRow[rowIndex].removeAll(keepingCapacity: true)
            underlineExtrasByRow[rowIndex].removeAll(keepingCapacity: true)
        }
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
        let rowSearch: [SearchHighlightRange]
        if searchHighlights.isEmpty {
            rowSearch = []
        } else {
            rowSearch = searchHighlights.filter { $0.row == rowIndex }
        }

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

        // 1) Background for every cell (selection invert / search gold / current peach).
        // Default terminal bg is transparent (ba=0) so Kitty below_bg shows through the
        // letterbox/clear color; only non-default or highlighted cells cover images.
        let defBr = Float(defBg.r) / 255
        let defBgG = Float(defBg.g) / 255
        let defBb = Float(defBg.b) / 255
        let ulTh = Float(max(1, metrics.underlineThicknessPx))
        let ulY = y + Float(metrics.underlineTopPx)
        let hasHighlight = selStart != nil || !rowSearch.isEmpty
        let rowBase = rowIndex * layout.cols
        let originX = layout.originX + layout.padPx
        let cellW = layout.cellW
        let cellH = layout.cellH
        rowCells.withUnsafeBufferPointer { cellsBuf in
            gridCells.withUnsafeMutableBufferPointer { gridBuf in
                var col = 0
                while col < layout.cols {
                    let cell = cellsBuf.baseAddress.unsafelyUnwrapped + col
                    let x = (originX + Float(col) * cellW)
                        .rounded(.toNearestOrAwayFromZero)
                    let hl = hasHighlight ? highlight(for: col) : .none
                    let colors = CellPaintColors.pair(
                        fg: cell.pointee.fg, bg: cell.pointee.bg,
                        faint: cell.pointee.faint, highlight: hl
                    )
                    let fr = colors.ink.r, fgG = colors.ink.g, fb = colors.ink.b
                    let br = colors.fill.r, bgG = colors.fill.g, bb = colors.fill.b
                    let isDefaultBg = hl == .none
                        && abs(br - defBr) < 1e-4
                        && abs(bgG - defBgG) < 1e-4
                        && abs(bb - defBb) < 1e-4
                    let idx = rowBase + col
                    if idx < gridBuf.count {
                        gridBuf[idx] = CellInstance(
                            ox: x, oy: y, sx: cellW, sy: cellH,
                            u0: 0, v0: 0, u1: 0, v1: 0,
                            fr: fr, fg: fgG, fb: fb, fa: 1,
                            br: br, bg: bgG, bb: bb, ba: isDefaultBg ? 0 : 1
                        )
                    }
                    if cell.pointee.underline, rowIndex < underlineExtrasByRow.count {
                        underlineExtrasByRow[rowIndex].append(.make(
                            originX: x, originY: ulY,
                            width: cellW, height: ulTh,
                            u0: 0, v0: 0, u1: 0, v1: 0,
                            fr: fr, fg: fgG, fb: fb, fa: 1,
                            br: fr, bg: fgG, bb: fb, ba: 1
                        ))
                    }
                    col += 1
                }
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
            cursorCol: cursorCol,
            metrics: metrics,
            layout: layout
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
            case .run(let start, let end, let style, let contentHash, let face):
                paintShapedRun(
                    start: start, end: end, style: style,
                    contentHash: contentHash, face: face,
                    rowCells: rowCells, rowIndex: rowIndex,
                    metrics: metrics, layout: layout,
                    cellWInt: cellWInt, cellHInt: cellHInt
                )
            }
        }
    }

    enum RunSeg {
        case run(
            start: Int, end: Int, style: TextStyleKey,
            contentHash: UInt64, face: CodepointCache.FaceKind
        )
        case wide(col: Int)
    }

    /// Segment a row into shape runs (Ghostty `RunIterator`).
    ///
    /// Breaks on: text style (not bg), wide heads, font index (Ghostty
    /// `getIndex`), selection / search, cursor, and `fi`/`fl`/`st`.
    /// Spaces and empty cells stay in the run. Trailing empty cells are trimmed.
    func segmentRuns(
        _ cells: [TerminalRowCell],
        selectionLo: Int?,
        selectionHi: Int?,
        highlightBreaks: [Int] = [],
        cursorCol: Int?,
        metrics: CellMetrics,
        layout: LayoutKey
    ) -> [RunSeg] {
        var segs: [RunSeg] = []
        var i = 0
        var runStart: Int?
        var runStyle: TextStyleKey?
        var runFace: CodepointCache.FaceKind?
        var runHash = ShaperCache.fnvOffset

        func faceKind(of c: TerminalRowCell) -> CodepointCache.FaceKind {
            if c.cp == 0 || (c.cp >= 0x20 && c.cp <= 0x7E) { return .primary }
            return codepoints.faceKind(
                cp: c.cp,
                bold: c.bold,
                italic: c.italic,
                fontPx: layout.fontPx,
                primary: primaryFont(bold: c.bold, italic: c.italic, metrics: metrics),
                nerdFaces: metrics.nerdFaces
            )
        }

        // Ghostty: trim the right edge of empty cells before forming runs.
        var maxCol = cells.count
        while maxCol > 0 {
            let c = cells[maxCol - 1]
            if !c.isWideTail, c.cp != 0 || !c.text.isEmpty { break }
            maxCol -= 1
        }

        func beginRun(at col: Int, style: TextStyleKey, cp: UInt32, face: CodepointCache.FaceKind) {
            runStart = col
            runStyle = style
            runFace = face
            runHash = ShaperCache.fnvOffset
            ShaperCache.mixCell(&runHash, cp: cp, cluster: 0)
        }

        func flushRun(upTo end: Int) {
            guard let s = runStart, let st = runStyle, s < end else {
                runStart = nil
                runStyle = nil
                runFace = nil
                return
            }
            ShaperCache.mix(&runHash, UInt64(end - s))
            segs.append(.run(
                start: s, end: end, style: st,
                contentHash: runHash, face: runFace ?? .primary
            ))
            runStart = nil
            runStyle = nil
            runFace = nil
        }

        /// True if we must end the current run before absorbing column `i`.
        func mustBreakBefore(i: Int, runStart: Int) -> Bool {
            if i <= runStart { return false }

            // Selection / search: break at enter (lo) and leave (hi+1). Inclusive hi.
            if let lo = selectionLo, let hi = selectionHi {
                if i == lo { return true }
                if i == hi + 1 { return true }
            }
            if !highlightBreaks.isEmpty, highlightBreaks.contains(i) { return true }

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
            let face = faceKind(of: c)
            if runStart == nil {
                beginRun(at: i, style: st, cp: c.cp, face: face)
            } else if st != runStyle || face != runFace {
                flushRun(upTo: i)
                beginRun(at: i, style: st, cp: c.cp, face: face)
            } else if let s = runStart {
                ShaperCache.mixCell(&runHash, cp: c.cp, cluster: i - s)
            }
            i += 1
        }
        flushRun(upTo: maxCol)
        return segs
    }

    /// Featured primary faces + ASCII glyph tables for this metrics / atlas gen.
    func preparePaintFonts(metrics: CellMetrics) {
        let gen = atlas.packGeneration
        let fontsFresh = paintFeat == nil
            || paintFeatPx != metrics.fontPx
            || paintFeatLiga != fontLigatures
        if fontsFresh {
            let regular = shaper.featuredFont(metrics.font, ligatures: fontLigatures)
            let bold = shaper.featuredFont(metrics.fontBold, ligatures: fontLigatures)
            let italic = shaper.featuredFont(metrics.fontItalic, ligatures: fontLigatures)
            let boldItalic = shaper.featuredFont(metrics.fontBoldItalic, ligatures: fontLigatures)
            paintFeat = (regular, bold, italic, boldItalic)
            paintAsciiGlyphs = (
                Self.asciiGlyphTable(regular),
                Self.asciiGlyphTable(bold),
                Self.asciiGlyphTable(italic),
                Self.asciiGlyphTable(boldItalic)
            )
            paintFeatPx = metrics.fontPx
            paintFeatLiga = fontLigatures
            paintFeatGen = gen
            paintAsciiEntries = Array(repeating: nil, count: 512)
            return
        }
        if paintFeatGen != gen {
            paintFeatGen = gen
            paintAsciiEntries = Array(repeating: nil, count: 512)
        }
    }

    func primaryFont(bold: Bool, italic: Bool, metrics: CellMetrics) -> CTFont {
        if let feat = paintFeat {
            switch (bold, italic) {
            case (true, true): return feat.boldItalic
            case (true, false): return feat.bold
            case (false, true): return feat.italic
            case (false, false): return feat.regular
            }
        }
        return shaper.featuredFont(metrics.font(bold: bold, italic: italic), ligatures: fontLigatures)
    }

    private static func asciiGlyphTable(_ font: CTFont) -> [CGGlyph] {
        var chars = [UniChar](32...126)
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        _ = CTFontGetGlyphsForCharacters(font, &chars, &glyphs, chars.count)
        var table = [CGGlyph](repeating: 0, count: 128)
        for (i, code) in (32...126).enumerated() {
            table[code] = glyphs[i]
        }
        return table
    }

    /// One primary-face cell: glyph + atlas, no shaper.
    func paintSinglePrimaryCell(
        col: Int,
        style: TextStyleKey,
        rowCells: [TerminalRowCell],
        rowIndex: Int,
        metrics: CellMetrics,
        layout: LayoutKey,
        cellWInt: Int,
        cellHInt: Int,
        shapedFont: CTFont
    ) {
        guard col < rowCells.count, col < layout.cols else { return }
        let cp = rowCells[col].cp
        if cp == 0 { return }

        let entry: GlyphAtlas.Entry
        if cp < 128 {
            let slot = Int(cp) + (style.bold ? 128 : 0) + (style.italic ? 256 : 0)
            if slot < paintAsciiEntries.count, let hit = paintAsciiEntries[slot] {
                entry = hit
            } else {
                let g: CGGlyph
                if let tables = paintAsciiGlyphs {
                    switch (style.bold, style.italic) {
                    case (true, true): g = tables.boldItalic[Int(cp)]
                    case (true, false): g = tables.bold[Int(cp)]
                    case (false, true): g = tables.italic[Int(cp)]
                    case (false, false): g = tables.regular[Int(cp)]
                    }
                } else {
                    g = 0
                }
                if g == 0 {
                    entry = GlyphAtlas.Entry(uv: atlas.emptyUV)
                } else {
                    entry = atlas.entry(
                        glyph: g,
                        bold: style.bold,
                        italic: style.italic,
                        font: shapedFont,
                        fontPx: layout.fontPx,
                        cellHeightPx: cellHInt,
                        cellBaselinePx: metrics.cellBaselinePx,
                        cellWidthPx: cellWInt,
                        faceWidthPx: metrics.faceWidthPx
                    )
                }
                if slot < paintAsciiEntries.count {
                    paintAsciiEntries[slot] = entry
                }
            }
        } else {
            var g = CGGlyph()
            if cp <= 0xFFFF {
                var ch = UniChar(cp)
                if !CTFontGetGlyphsForCharacters(shapedFont, &ch, &g, 1) {
                    g = 0
                }
            }
            if g == 0 { return }
            entry = atlas.entry(
                glyph: g,
                bold: style.bold,
                italic: style.italic,
                font: shapedFont,
                fontPx: layout.fontPx,
                cellHeightPx: cellHInt,
                cellBaselinePx: metrics.cellBaselinePx,
                cellWidthPx: cellWInt,
                faceWidthPx: metrics.faceWidthPx
            )
        }
        if entry.pixelW < 0.5 || entry.pixelH < 0.5 { return }

        let rowTop = (layout.originY + layout.padPx + Float(rowIndex) * layout.cellH)
            .rounded(.toNearestOrAwayFromZero)
        var fr = Float(style.fr) / 255
        var fgG = Float(style.fg) / 255
        var fb = Float(style.fb) / 255
        if style.faint { fr *= 0.5; fgG *= 0.5; fb *= 0.5 }
        appendGlyphExtra(
            entry: entry,
            col: col, rowIndex: rowIndex, rowTop: rowTop,
            xOffset: 0, yOffset: 0,
            fr: fr, fg: fgG, fb: fb,
            layout: layout
        )
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
        face: CodepointCache.FaceKind,
        rowCells: [TerminalRowCell],
        rowIndex: Int,
        metrics: CellMetrics,
        layout: LayoutKey,
        cellWInt: Int,
        cellHInt: Int
    ) {
        guard start < end else { return }

        let shapedFont = primaryFont(bold: style.bold, italic: style.italic, metrics: metrics)

        // Ghostty: a run is one font index. Primary face is shaped; else cell-by-cell.
        if face == .primary {
            // One cell cannot ligate. Combining clusters still go through the shaper.
            if end - start == 1, rowCells[start].text.unicodeScalars.count <= 1 {
                paintSinglePrimaryCell(
                    col: start, style: style, rowCells: rowCells,
                    rowIndex: rowIndex, metrics: metrics, layout: layout,
                    cellWInt: cellWInt, cellHInt: cellHInt, shapedFont: shapedFont
                )
                return
            }
            paintLigatureRun(
                start: start, end: end, style: style, contentHash: contentHash,
                rowCells: rowCells, rowIndex: rowIndex, metrics: metrics, layout: layout,
                cellWInt: cellWInt, cellHInt: cellHInt,
                shapedFont: shapedFont
            )
            return
        }

        paintCellsIndividually(
            start: start, end: end, style: style, rowCells: rowCells,
            rowIndex: rowIndex, metrics: metrics, layout: layout,
            cellWInt: cellWInt, cellHInt: cellHInt,
            primary: shapedFont, nerdFaces: metrics.nerdFaces
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
                layout: layout
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
            if cellText.unicodeScalars.count == 1, rowCells[col].cp != 0 {
                switch codepoints.resolve(
                    cp: rowCells[col].cp,
                    bold: style.bold,
                    italic: style.italic,
                    fontPx: layout.fontPx,
                    primary: primary,
                    nerdFaces: nerdFaces
                ) {
                case .sprite:
                    entry = atlas.entrySprite(
                        codepoint: rowCells[col].cp,
                        cellWidthPx: cellWInt,
                        cellHeightPx: cellHInt,
                        cellBaselinePx: metrics.cellBaselinePx
                    )
                case .glyph(let font, let glyph, _):
                    entry = atlas.entry(
                        glyph: glyph,
                        bold: style.bold,
                        italic: style.italic,
                        font: font,
                        fontPx: layout.fontPx,
                        cellHeightPx: cellHInt,
                        cellBaselinePx: metrics.cellBaselinePx,
                        cellWidthPx: cellWInt,
                        faceWidthPx: metrics.faceWidthPx
                    )
                case .missing:
                    continue
                }
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
                layout: layout
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
        layout: LayoutKey
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

        if rowIndex < glyphExtrasByRow.count {
            glyphExtrasByRow[rowIndex].append(.make(
                originX: ox, originY: oy,
                width: max(1, pwG), height: max(1, phG),
                u0: entry.uv.x, v0: entry.uv.y, u1: entry.uv.z, v1: entry.uv.w,
                fr: ifr, fg: ifg, fb: ifb, fa: 1,
                br: 0, bg: 0, bb: 0, ba: 0
            ))
        }
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
        metrics.nerdFaces
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
        if rowIndex < glyphExtrasByRow.count {
            glyphExtrasByRow[rowIndex].append(.make(
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


}
