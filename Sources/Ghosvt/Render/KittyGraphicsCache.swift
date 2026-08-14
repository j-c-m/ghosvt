import CGhosttyVT
import Foundation
import Metal

/// Per-session Kitty graphics texture + placement snapshot for Metal.
///
/// Call `sync(terminal:device:layout:shellShiftY:visualY:)` under the session
/// lock (or while terminal is idle) so borrowed pixel pointers stay valid.
/// Textures are keyed by image_id + image generation.
///
/// Absolute placements use `ghostty_kitty_graphics_placement_render_info`.
/// Virtual (unicode placeholder) placements scan viewport cells for U+10EEEE
/// and resolve fragment geometry via `KittyVirtualUnicode`.
final class KittyGraphicsCache {
    enum Layer {
        case belowBg
        case belowText
        case aboveText
    }

    struct DrawQuad {
        var originX: Float
        var originY: Float
        var width: Float
        var height: Float
        var u0: Float
        var v0: Float
        var u1: Float
        var v1: Float
        var texture: MTLTexture
        var z: Int32
    }

    private struct TextureEntry {
        var texture: MTLTexture
        var generation: UInt64
        var width: UInt32
        var height: UInt32
    }

    /// Virtual placement storage meta (grid size for aspect-fit).
    private struct VirtualMeta {
        var imageID: UInt32
        var placementID: UInt32
        var columns: UInt32
        var rows: UInt32
    }

    private var textures: [UInt32: TextureEntry] = [:]
    private var lastStorageGeneration: UInt64 = 0
    private var belowBg: [DrawQuad] = []
    private var belowText: [DrawQuad] = []
    private var aboveText: [DrawQuad] = []
    private var hasAny = false

    var isEmpty: Bool { !hasAny }

    func quads(for layer: Layer) -> [DrawQuad] {
        switch layer {
        case .belowBg: return belowBg
        case .belowText: return belowText
        case .aboveText: return aboveText
        }
    }

    /// Refresh placement geometry and textures for the active screen.
    /// Must not mutate the terminal during this call.
    func sync(
        terminal: GhosttyTerminal,
        device: MTLDevice,
        layout: TerminalRenderer.LayoutKey,
        shellShiftY: Float,
        visualY: Float
    ) {
        var graphics: GhosttyKittyGraphics?
        let gr = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS, &graphics)
        guard gr == GHOSTTY_SUCCESS, let graphics else {
            clearPlacements()
            return
        }

        var generation: UInt64 = 0
        _ = ghostty_kitty_graphics_get(graphics, GHOSTTY_KITTY_GRAPHICS_DATA_GENERATION, &generation)

        // Always recompute geometry (scroll / resize). Only re-upload textures on gen change.
        let storageChanged = generation != lastStorageGeneration
        lastStorageGeneration = generation

        if generation == 0 {
            clearPlacements()
            if storageChanged { textures.removeAll(keepingCapacity: true) }
            return
        }

        var iterOpt: GhosttyKittyGraphicsPlacementIterator?
        guard ghostty_kitty_graphics_placement_iterator_new(nil, &iterOpt) == GHOSTTY_SUCCESS,
              var placeIter = iterOpt
        else {
            clearPlacements()
            return
        }
        defer { ghostty_kitty_graphics_placement_iterator_free(placeIter) }

        _ = ghostty_kitty_graphics_get(
            graphics,
            GHOSTTY_KITTY_GRAPHICS_DATA_PLACEMENT_ITERATOR,
            &placeIter
        )

        var nextBelowBg: [DrawQuad] = []
        var nextBelowText: [DrawQuad] = []
        var nextAboveText: [DrawQuad] = []
        var seenImageIDs = Set<UInt32>()
        var virtualMetas: [VirtualMeta] = []
        var hasVirtual = false
        let content = shellContentBox(
            layout: layout,
            shellShiftY: shellShiftY,
            visualY: visualY
        )

        while ghostty_kitty_graphics_placement_next(placeIter) {
            var imageID: UInt32 = 0
            var placementID: UInt32 = 0
            var isVirtual = false
            var z: Int32 = 0
            var columns: UInt32 = 0
            var rows: UInt32 = 0
            var xOffset: UInt32 = 0
            var yOffset: UInt32 = 0
            _ = ghostty_kitty_graphics_placement_get(
                placeIter, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IMAGE_ID, &imageID
            )
            _ = ghostty_kitty_graphics_placement_get(
                placeIter, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_PLACEMENT_ID, &placementID
            )
            _ = ghostty_kitty_graphics_placement_get(
                placeIter, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IS_VIRTUAL, &isVirtual
            )
            _ = ghostty_kitty_graphics_placement_get(
                placeIter, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_Z, &z
            )
            _ = ghostty_kitty_graphics_placement_get(
                placeIter, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_COLUMNS, &columns
            )
            _ = ghostty_kitty_graphics_placement_get(
                placeIter, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_ROWS, &rows
            )
            _ = ghostty_kitty_graphics_placement_get(
                placeIter, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_X_OFFSET, &xOffset
            )
            _ = ghostty_kitty_graphics_placement_get(
                placeIter, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_Y_OFFSET, &yOffset
            )

            // Virtual placements are only drawn where U+10EEEE runs appear.
            if isVirtual {
                hasVirtual = true
                virtualMetas.append(VirtualMeta(
                    imageID: imageID,
                    placementID: placementID,
                    columns: columns,
                    rows: rows
                ))
                if let image = ghostty_kitty_graphics_image(graphics, imageID) {
                    seenImageIDs.insert(imageID)
                    _ = ensureTexture(
                        device: device,
                        imageID: imageID,
                        image: image
                    )
                }
                continue
            }

            guard let image = ghostty_kitty_graphics_image(graphics, imageID) else { continue }
            seenImageIDs.insert(imageID)

            guard let texture = ensureTexture(
                device: device,
                imageID: imageID,
                image: image
            ) else { continue }

            var info = GhosttyKittyGraphicsPlacementRenderInfo()
            info.size = MemoryLayout<GhosttyKittyGraphicsPlacementRenderInfo>.size
            let ir = ghostty_kitty_graphics_placement_render_info(placeIter, image, terminal, &info)
            guard ir == GHOSTTY_SUCCESS, info.viewport_visible else { continue }
            guard info.pixel_width > 0, info.pixel_height > 0 else { continue }

            // Cell origin + protocol X/Y pixel offsets within the anchor cell.
            let ox = layout.originX + layout.padPx
                + Float(info.viewport_col) * layout.cellW
                + Float(xOffset)
            let oy = layout.originY + layout.padPx
                + Float(info.viewport_row) * layout.cellH
                + visualY + shellShiftY
                + Float(yOffset)

            let imgW = max(1, Float(texture.width))
            let imgH = max(1, Float(texture.height))
            let u0 = Float(info.source_x) / imgW
            let v0 = Float(info.source_y) / imgH
            let u1 = Float(info.source_x + info.source_width) / imgW
            let v1 = Float(info.source_y + info.source_height) / imgH

            guard let quad = makeClippedQuad(
                originX: ox,
                originY: oy,
                width: Float(info.pixel_width),
                height: Float(info.pixel_height),
                u0: u0, v0: v0, u1: u1, v1: v1,
                texture: texture,
                z: z,
                content: content
            ) else { continue }

            appendQuad(quad, to: &nextBelowBg, &nextBelowText, &nextAboveText)
        }

        if hasVirtual {
            appendVirtualQuads(
                terminal: terminal,
                graphics: graphics,
                device: device,
                layout: layout,
                shellShiftY: shellShiftY,
                visualY: visualY,
                content: content,
                virtualMetas: virtualMetas,
                seenImageIDs: &seenImageIDs,
                nextBelowBg: &nextBelowBg,
                nextBelowText: &nextBelowText,
                nextAboveText: &nextAboveText
            )
        }

        // Stable order within a layer: lower z first, then y, x.
        let sortKey: (DrawQuad, DrawQuad) -> Bool = { a, b in
            if a.z != b.z { return a.z < b.z }
            if a.originY != b.originY { return a.originY < b.originY }
            return a.originX < b.originX
        }
        nextBelowBg.sort(by: sortKey)
        nextBelowText.sort(by: sortKey)
        nextAboveText.sort(by: sortKey)

        belowBg = nextBelowBg
        belowText = nextBelowText
        aboveText = nextAboveText
        hasAny = !(belowBg.isEmpty && belowText.isEmpty && aboveText.isEmpty)

        // Drop textures for deleted images when storage mutates.
        if storageChanged {
            textures = textures.filter { seenImageIDs.contains($0.key) }
        }
    }

    // MARK: - Virtual placeholders

    private func appendVirtualQuads(
        terminal: GhosttyTerminal,
        graphics: GhosttyKittyGraphics,
        device: MTLDevice,
        layout: TerminalRenderer.LayoutKey,
        shellShiftY: Float,
        visualY: Float,
        content: ContentBox,
        virtualMetas: [VirtualMeta],
        seenImageIDs: inout Set<UInt32>,
        nextBelowBg: inout [DrawQuad],
        nextBelowText: inout [DrawQuad],
        nextAboveText: inout [DrawQuad]
    ) {
        let cellW = UInt32(max(1, layout.cellW.rounded()))
        let cellH = UInt32(max(1, layout.cellH.rounded()))
        let cols = layout.cols
        let rows = layout.rows

        var run: KittyVirtualUnicode.Incomplete?
        var graphemeBuf = [UInt32](repeating: 0, count: 16)

        func flushRun() {
            guard let done = run?.complete() else {
                run = nil
                return
            }
            run = nil
            emitVirtual(
                placement: done,
                terminal: terminal,
                graphics: graphics,
                device: device,
                layout: layout,
                shellShiftY: shellShiftY,
                visualY: visualY,
                content: content,
                cellW: cellW,
                cellH: cellH,
                virtualMetas: virtualMetas,
                seenImageIDs: &seenImageIDs,
                nextBelowBg: &nextBelowBg,
                nextBelowText: &nextBelowText,
                nextAboveText: &nextAboveText
            )
        }

        for row in 0..<rows {
            // Fast path: skip rows without the virtual-placeholder flag.
            var rowRef = GhosttyGridRef()
            rowRef.size = MemoryLayout<GhosttyGridRef>.size
            var point = GhosttyPoint()
            point.tag = GHOSTTY_POINT_TAG_VIEWPORT
            point.value.coordinate.x = 0
            point.value.coordinate.y = UInt32(row)
            guard ghostty_terminal_grid_ref(terminal, point, &rowRef) == GHOSTTY_SUCCESS else {
                flushRun()
                continue
            }
            var ghosttyRow: GhosttyRow = 0
            if ghostty_grid_ref_row(&rowRef, &ghosttyRow) == GHOSTTY_SUCCESS {
                var hasPlaceholder = false
                _ = ghostty_row_get(
                    ghosttyRow,
                    GHOSTTY_ROW_DATA_KITTY_VIRTUAL_PLACEHOLDER,
                    &hasPlaceholder
                )
                if !hasPlaceholder {
                    flushRun()
                    continue
                }
            }

            for col in 0..<cols {
                var ref = GhosttyGridRef()
                ref.size = MemoryLayout<GhosttyGridRef>.size
                var pt = GhosttyPoint()
                pt.tag = GHOSTTY_POINT_TAG_VIEWPORT
                pt.value.coordinate.x = UInt16(col)
                pt.value.coordinate.y = UInt32(row)
                guard ghostty_terminal_grid_ref(terminal, pt, &ref) == GHOSTTY_SUCCESS else {
                    flushRun()
                    continue
                }

                var cell: GhosttyCell = 0
                guard ghostty_grid_ref_cell(&ref, &cell) == GHOSTTY_SUCCESS else {
                    flushRun()
                    continue
                }
                var cp: UInt32 = 0
                _ = ghostty_cell_get(cell, GHOSTTY_CELL_DATA_CODEPOINT, &cp)
                if cp != KittyVirtualUnicode.placeholder {
                    flushRun()
                    continue
                }

                var style = GhosttyStyle()
                style.size = MemoryLayout<GhosttyStyle>.size
                ghostty_style_default(&style)
                _ = ghostty_grid_ref_style(&ref, &style)

                var graphemeLen: Int = 0
                let gr = graphemeBuf.withUnsafeMutableBufferPointer { buf -> GhosttyResult in
                    ghostty_grid_ref_graphemes(
                        &ref,
                        buf.baseAddress,
                        buf.count,
                        &graphemeLen
                    )
                }
                if gr == GHOSTTY_OUT_OF_SPACE, graphemeLen > graphemeBuf.count {
                    graphemeBuf = [UInt32](repeating: 0, count: graphemeLen)
                    _ = graphemeBuf.withUnsafeMutableBufferPointer { buf in
                        ghostty_grid_ref_graphemes(
                            &ref,
                            buf.baseAddress,
                            buf.count,
                            &graphemeLen
                        )
                    }
                }

                let curr = graphemeBuf.withUnsafeBufferPointer { buf in
                    let slice = UnsafeBufferPointer(start: buf.baseAddress, count: max(0, graphemeLen))
                    return KittyVirtualUnicode.Incomplete.decode(
                        viewportCol: col,
                        viewportRow: row,
                        style: style,
                        graphemes: slice
                    )
                }

                if var prev = run {
                    if prev.append(curr) {
                        run = prev
                    } else {
                        flushRun()
                        var seeded = curr
                        seeded.seedDefaults()
                        run = seeded
                    }
                } else {
                    var seeded = curr
                    seeded.seedDefaults()
                    run = seeded
                }
            }
            // Runs never span rows.
            flushRun()
        }
    }

    private func emitVirtual(
        placement: KittyVirtualUnicode.Placement,
        terminal: GhosttyTerminal,
        graphics: GhosttyKittyGraphics,
        device: MTLDevice,
        layout: TerminalRenderer.LayoutKey,
        shellShiftY: Float,
        visualY: Float,
        content: ContentBox,
        cellW: UInt32,
        cellH: UInt32,
        virtualMetas: [VirtualMeta],
        seenImageIDs: inout Set<UInt32>,
        nextBelowBg: inout [DrawQuad],
        nextBelowText: inout [DrawQuad],
        nextAboveText: inout [DrawQuad]
    ) {
        _ = terminal
        guard let meta = lookupVirtualMeta(
            imageID: placement.imageId,
            placementID: placement.placementId,
            metas: virtualMetas
        ) else { return }

        guard let image = ghostty_kitty_graphics_image(graphics, placement.imageId) else {
            return
        }
        seenImageIDs.insert(placement.imageId)
        guard let texture = ensureTexture(
            device: device,
            imageID: placement.imageId,
            image: image
        ) else { return }

        var imgW: UInt32 = 0
        var imgH: UInt32 = 0
        _ = ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_WIDTH, &imgW)
        _ = ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_HEIGHT, &imgH)
        guard imgW > 0, imgH > 0 else { return }

        let grid = KittyVirtualUnicode.gridSize(
            columns: meta.columns,
            rows: meta.rows,
            imageWidth: imgW,
            imageHeight: imgH,
            cellWidth: cellW,
            cellHeight: cellH
        )
        guard grid.columns > 0, grid.rows > 0 else { return }

        guard let rp = KittyVirtualUnicode.renderPlacement(
            placement: placement,
            gridColumns: grid.columns,
            gridRows: grid.rows,
            imageWidth: imgW,
            imageHeight: imgH,
            cellWidth: cellW,
            cellHeight: cellH
        ) else { return }

        guard rp.destWidth > 0, rp.destHeight > 0 else { return }
        guard rp.sourceWidth > 0, rp.sourceHeight > 0 else { return }

        // Virtual uses aspect-fit offsets only (not protocol X/Y storage offsets).
        let ox = layout.originX + layout.padPx
            + Float(placement.viewportCol) * layout.cellW
            + Float(rp.offsetX)
        let oy = layout.originY + layout.padPx
            + Float(placement.viewportRow) * layout.cellH
            + visualY + shellShiftY
            + Float(rp.offsetY)

        let texW = max(1, Float(texture.width))
        let texH = max(1, Float(texture.height))
        let u0 = Float(rp.sourceX) / texW
        let v0 = Float(rp.sourceY) / texH
        let u1 = Float(rp.sourceX + rp.sourceWidth) / texW
        let v1 = Float(rp.sourceY + rp.sourceHeight) / texH

        guard let quad = makeClippedQuad(
            originX: ox,
            originY: oy,
            width: Float(rp.destWidth),
            height: Float(rp.destHeight),
            u0: u0, v0: v0, u1: u1, v1: v1,
            texture: texture,
            z: KittyVirtualUnicode.virtualZ,
            content: content
        ) else { return }

        appendQuad(quad, to: &nextBelowBg, &nextBelowText, &nextAboveText)
    }

    // MARK: - Geometry helpers

    /// Shell content box in surface pixels (excludes letterbox + stolen search row).
    private struct ContentBox {
        var minX: Float
        var minY: Float
        var maxX: Float
        var maxY: Float
    }

    private func shellContentBox(
        layout: TerminalRenderer.LayoutKey,
        shellShiftY: Float,
        visualY: Float
    ) -> ContentBox {
        let minX = layout.originX + layout.padPx
        let minY = layout.originY + layout.padPx + visualY + shellShiftY
        return ContentBox(
            minX: minX,
            minY: minY,
            maxX: minX + Float(layout.cols) * layout.cellW,
            maxY: minY + Float(layout.rows) * layout.cellH
        )
    }

    /// Intersect dest rect with the shell content box; crop UVs proportionally.
    /// Returns nil when fully outside or degenerate after clip.
    private func makeClippedQuad(
        originX: Float,
        originY: Float,
        width: Float,
        height: Float,
        u0: Float,
        v0: Float,
        u1: Float,
        v1: Float,
        texture: MTLTexture,
        z: Int32,
        content: ContentBox
    ) -> DrawQuad? {
        guard width > 0, height > 0 else { return nil }

        let left = originX
        let right = originX + width
        let top = originY
        let bottom = originY + height

        let cl = max(left, content.minX)
        let cr = min(right, content.maxX)
        let ct = max(top, content.minY)
        let cb = min(bottom, content.maxY)
        guard cl < cr, ct < cb else { return nil }

        // Linear map from dest pixels → UV.
        let du = (u1 - u0) / width
        let dv = (v1 - v0) / height
        let cu0 = u0 + (cl - left) * du
        let cu1 = u0 + (cr - left) * du
        let cv0 = v0 + (ct - top) * dv
        let cv1 = v0 + (cb - top) * dv

        return DrawQuad(
            originX: cl,
            originY: ct,
            width: cr - cl,
            height: cb - ct,
            u0: cu0, v0: cv0, u1: cu1, v1: cv1,
            texture: texture,
            z: z
        )
    }

    private func appendQuad(
        _ quad: DrawQuad,
        to belowBg: inout [DrawQuad],
        _ belowText: inout [DrawQuad],
        _ aboveText: inout [DrawQuad]
    ) {
        switch layer(for: quad.z) {
        case .belowBg: belowBg.append(quad)
        case .belowText: belowText.append(quad)
        case .aboveText: aboveText.append(quad)
        }
    }

    private func lookupVirtualMeta(
        imageID: UInt32,
        placementID: UInt32,
        metas: [VirtualMeta]
    ) -> VirtualMeta? {
        if placementID > 0 {
            return metas.first { $0.imageID == imageID && $0.placementID == placementID }
        }
        // No placement id: first virtual placement for this image.
        return metas.first { $0.imageID == imageID }
    }

    private func clearPlacements() {
        belowBg = []
        belowText = []
        aboveText = []
        hasAny = false
    }

    private func layer(for z: Int32) -> Layer {
        // Kitty / Ghostty conventions (see GhosttyKittyPlacementLayer).
        let halfMin = Int32.min / 2
        if z < halfMin { return .belowBg }
        if z < 0 { return .belowText }
        return .aboveText
    }

    private func ensureTexture(
        device: MTLDevice,
        imageID: UInt32,
        image: GhosttyKittyGraphicsImage
    ) -> MTLTexture? {
        var gen: UInt64 = 0
        var width: UInt32 = 0
        var height: UInt32 = 0
        var format: GhosttyKittyImageFormat = GHOSTTY_KITTY_IMAGE_FORMAT_RGBA
        var dataLen: Int = 0
        var dataPtr: UnsafePointer<UInt8>?

        _ = ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_GENERATION, &gen)
        _ = ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_WIDTH, &width)
        _ = ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_HEIGHT, &height)
        _ = ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_FORMAT, &format)
        _ = ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_DATA_LEN, &dataLen)
        let pr = ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_DATA_PTR, &dataPtr)
        // Pending payload: keep old texture if any.
        if pr == GHOSTTY_NO_VALUE || dataPtr == nil || width == 0 || height == 0 {
            return textures[imageID]?.texture
        }

        if let existing = textures[imageID], existing.generation == gen {
            return existing.texture
        }

        guard let rgba = rgbaBytes(
            format: format,
            width: Int(width),
            height: Int(height),
            data: dataPtr!,
            dataLen: dataLen
        ) else { return textures[imageID]?.texture }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: Int(width),
            height: Int(height),
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else {
            return textures[imageID]?.texture
        }
        rgba.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            tex.replace(
                region: MTLRegionMake2D(0, 0, Int(width), Int(height)),
                mipmapLevel: 0,
                withBytes: base,
                bytesPerRow: Int(width) * 4
            )
        }
        textures[imageID] = TextureEntry(
            texture: tex,
            generation: gen,
            width: width,
            height: height
        )
        return tex
    }

    private func rgbaBytes(
        format: GhosttyKittyImageFormat,
        width: Int,
        height: Int,
        data: UnsafePointer<UInt8>,
        dataLen: Int
    ) -> [UInt8]? {
        let pixels = width * height
        switch format {
        case GHOSTTY_KITTY_IMAGE_FORMAT_RGBA:
            guard dataLen >= pixels * 4 else { return nil }
            return Array(UnsafeBufferPointer(start: data, count: pixels * 4))
        case GHOSTTY_KITTY_IMAGE_FORMAT_RGB:
            guard dataLen >= pixels * 3 else { return nil }
            var out = [UInt8](repeating: 255, count: pixels * 4)
            for i in 0..<pixels {
                out[i * 4 + 0] = data[i * 3 + 0]
                out[i * 4 + 1] = data[i * 3 + 1]
                out[i * 4 + 2] = data[i * 3 + 2]
                out[i * 4 + 3] = 255
            }
            return out
        case GHOSTTY_KITTY_IMAGE_FORMAT_GRAY:
            guard dataLen >= pixels else { return nil }
            var out = [UInt8](repeating: 255, count: pixels * 4)
            for i in 0..<pixels {
                let g = data[i]
                out[i * 4 + 0] = g
                out[i * 4 + 1] = g
                out[i * 4 + 2] = g
                out[i * 4 + 3] = 255
            }
            return out
        case GHOSTTY_KITTY_IMAGE_FORMAT_GRAY_ALPHA:
            guard dataLen >= pixels * 2 else { return nil }
            var out = [UInt8](repeating: 255, count: pixels * 4)
            for i in 0..<pixels {
                let g = data[i * 2 + 0]
                let a = data[i * 2 + 1]
                out[i * 4 + 0] = g
                out[i * 4 + 1] = g
                out[i * 4 + 2] = g
                out[i * 4 + 3] = a
            }
            return out
        default:
            return nil
        }
    }
}
