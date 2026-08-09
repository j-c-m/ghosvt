import CGhosttyVT
import CoreText
import Foundation
import Metal
import QuartzCore

// MARK: - Cursor
extension TerminalRenderer {
    func cursorBlinkOn(renderState: GhosttyRenderState) -> Bool {
        var blinking = false
        _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_BLINKING, &blinking)
        guard blinking else { return true }
        let t = CACurrentMediaTime()
        return Int(t / blinkPeriod) % 2 == 0
    }

    func appendCursor(
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

        // cursor-color = cell-foreground, cursor-text = cell-background (OSC 12 → fill only).
        var cellInk = CellPaintColors.RGB(defFg)
        var cellFill = CellPaintColors.RGB(DefaultColors.background)
        let gIdx = Int(cy) * layout.cols + Int(cx)
        if gIdx >= 0, gIdx < gridCells.count {
            let cell = gridCells[gIdx]
            cellInk = CellPaintColors.RGB(r: cell.fr, g: cell.fg, b: cell.fb)
            cellFill = CellPaintColors.RGB(r: cell.br, g: cell.bg, b: cell.bb)
        }
        let osc: GhosttyColorRgb? = colors.cursor_has_value ? colors.cursor : nil
        let cur = CellPaintColors.cursor(cellInk: cellInk, cellFill: cellFill, defFg: defFg, oscCursor: osc)
        let cr = cur.fill.r, cgC = cur.fill.g, cb = cur.fill.b
        let tr = cur.text.r, tg = cur.text.g, tb = cur.text.b

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
                fr: cr, fg: cgC, fb: cb, fa: 1,
                br: cr, bg: cgC, bb: cb, ba: 1
            ))
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE:
            let h = max(2, ch * 0.12).rounded(.toNearestOrAwayFromZero)
            instances.append(.make(
                originX: x, originY: y + ch - h, width: cw, height: h,
                u0: 0, v0: 0, u1: 0, v1: 0,
                fr: cr, fg: cgC, fb: cb, fa: 1,
                br: cr, bg: cgC, bb: cb, ba: 1
            ))
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW:
            let t: Float = max(1, min(cw, ch) * 0.08).rounded(.toNearestOrAwayFromZero)
            instances.append(.make(originX: x, originY: y, width: cw, height: t, u0: 0, v0: 0, u1: 0, v1: 0, fr: cr, fg: cgC, fb: cb, fa: 1, br: cr, bg: cgC, bb: cb, ba: 1))
            instances.append(.make(originX: x, originY: y + ch - t, width: cw, height: t, u0: 0, v0: 0, u1: 0, v1: 0, fr: cr, fg: cgC, fb: cb, fa: 1, br: cr, bg: cgC, bb: cb, ba: 1))
            instances.append(.make(originX: x, originY: y, width: t, height: ch, u0: 0, v0: 0, u1: 0, v1: 0, fr: cr, fg: cgC, fb: cb, fa: 1, br: cr, bg: cgC, bb: cb, ba: 1))
            instances.append(.make(originX: x + cw - t, originY: y, width: t, height: ch, u0: 0, v0: 0, u1: 0, v1: 0, fr: cr, fg: cgC, fb: cb, fa: 1, br: cr, bg: cgC, bb: cb, ba: 1))
        default: // block: fill = cursor color, then glyph in cursor-text
            instances.append(.make(
                originX: x, originY: y, width: cw, height: ch,
                u0: 0, v0: 0, u1: 0, v1: 0,
                fr: tr, fg: tg, fb: tb, fa: 1,
                br: cr, bg: cgC, bb: cb, ba: 1
            ))
            appendCursorCellGlyph(
                to: &instances,
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

    /// Redraw character under block cursor from rowCellCache (no VT re-walk).
    func appendCursorCellGlyph(
        to instances: inout [CellInstance],
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
        let idx = row * layout.cols + col
        guard idx < rowCellCache.count else { return }
        let rc = rowCellCache[idx]
        if rc.isWideTail || rc.text.isEmpty { return }
        let span = rc.isWideHead ? 2 : 1
        let entry: GlyphAtlas.Entry
        if let cp = rc.text.unicodeScalars.first?.value,
           rc.text.unicodeScalars.count == 1,
           SpriteFace.covers(cp) {
            entry = atlas.entrySprite(
                codepoint: cp,
                cellWidthPx: cellWInt * span,
                cellHeightPx: cellHInt,
                cellBaselinePx: metrics.cellBaselinePx
            )
        } else {
            let font = metrics.font(bold: rc.bold, italic: rc.italic)
            entry = atlas.entry(
                text: rc.text,
                bold: rc.bold,
                italic: rc.italic,
                font: font,
                cellWidthPx: cellWInt * span,
                cellHeightPx: cellHInt,
                cellBaselinePx: metrics.cellBaselinePx,
                faceWidthPx: metrics.faceWidthPx * CGFloat(span),
                fallbackFonts: nerdFallbackFonts(metrics: metrics)
            )
        }
        if entry.pixelW < 0.5 { return }
        instances.append(.make(
            originX: cellX,
            originY: cellY,
            width: layout.cellW * Float(span),
            height: layout.cellH,
            u0: entry.uv.x, v0: entry.uv.y, u1: entry.uv.z, v1: entry.uv.w,
            fr: textR, fg: textG, fb: textB, fa: 1,
            br: 0, bg: 0, bb: 0, ba: 0
        ))
    }

    func appendIndicator(
        to instances: inout [CellInstance],
        text: String,
        metrics: CellMetrics,
        layout: LayoutKey,
        cellWInt: Int,
        cellHInt: Int
    ) {
        // Upper-right of the content grid (pad inset).
        let textW = Float(text.count) * layout.cellW
        let right = layout.originX + layout.padPx + Float(layout.cols) * layout.cellW - 4
        var ix = right - textW
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

}
