import CGhosttyVT
import Foundation
import Metal
import MetalKit
import QuartzCore

// MARK: - GPU
extension TerminalRenderer {
    func uploadInstances(_ instances: [CellInstance]) {
        frames.acquire()
        ensureInstanceCapacity(max(instances.count, 1))
        guard let raw = instanceBuffer?.contents() else {
            abortFrameSlot()
            lastDrawnCount = 0
            lastBgCount = 0
            lastFgCount = 0
            lastScrolledFgCount = 0
            return
        }
        var off = 0
        blitInstances(instances, to: raw, at: &off)
        lastDrawnCount = off
        lastScrolledFgCount = off
    }

    /// Pack `[bg | ink-by-row | underlines-by-row | scrolled overlay | fixed overlay]`.
    /// Scroll is `contentOffsetY` in the vertex shader, not baked into `oy`.
    func uploadGridLayers(
        bg: [CellInstance],
        inkByRow: [[CellInstance]],
        underlineByRow: [[CellInstance]],
        scrolledOverlay: [CellInstance],
        fixedOverlay: [CellInstance]
    ) {
        var extraN = scrolledOverlay.count + fixedOverlay.count
        for row in inkByRow { extraN += row.count }
        for row in underlineByRow { extraN += row.count }
        let total = bg.count + extraN
        frames.acquire()
        ensureInstanceCapacity(max(total, 1))
        guard let raw = instanceBuffer?.contents() else {
            abortFrameSlot()
            lastDrawnCount = 0
            lastBgCount = 0
            lastFgCount = 0
            lastScrolledFgCount = 0
            return
        }
        var off = 0
        blitInstances(bg, to: raw, at: &off)
        lastBgCount = off
        for row in inkByRow {
            blitInstances(row, to: raw, at: &off)
        }
        for row in underlineByRow {
            blitInstances(row, to: raw, at: &off)
        }
        blitInstances(scrolledOverlay, to: raw, at: &off)
        lastScrolledFgCount = off - lastBgCount
        blitInstances(fixedOverlay, to: raw, at: &off)
        lastFgCount = off - lastBgCount
        lastDrawnCount = off
    }

    private func blitInstances(
        _ src: [CellInstance],
        to dest: UnsafeMutableRawPointer,
        at offset: inout Int
    ) {
        guard !src.isEmpty else { return }
        let stride = MemoryLayout<CellInstance>.stride
        let dst = dest.advanced(by: offset * stride)
        src.withUnsafeBytes { raw in
            guard let p = raw.baseAddress else { return }
            dst.copyMemory(from: p, byteCount: src.count * stride)
        }
        offset += src.count
    }

    private func setFrameUniforms(
        _ enc: MTLRenderCommandEncoder,
        pw: Float,
        ph: Float,
        contentOffsetY: Float
    ) {
        var uni = FrameUniforms(viewportX: pw, viewportY: ph, contentOffsetY: contentOffsetY)
        enc.setVertexBytes(&uni, length: FrameUniforms.stride, index: 1)
    }

    /// Minimum on-screen time for this frame within the display’s Adaptive-Sync range.
    /// Active: GPU-paced (clamped). Idle on VRR: hold at the slowest supported rate.
    func presentDuration(contentActive: Bool) -> CFTimeInterval {
        if !adaptiveSync {
            return displayMinInterval
        }
        if contentActive {
            return min(displayMaxInterval, max(displayMinInterval, gpuTimeEMA.value))
        }
        return displayMaxInterval
    }

    /// Multi-pass present: Kitty z-layers interleaved with cell bg / ink.
    ///
    /// Instance buffer: `[bg | scrolled fg | fixed fg]`.
    /// Scrolled fg (ink, underlines, hover, cursor) uses `contentOffsetY`.
    /// Fixed fg (HUD, indicator, quit) is drawn with offset 0.
    func present(
        bgCount: Int,
        fgCount: Int,
        scrolledFgCount: Int,
        kitty: KittyGraphicsCache?,
        drawable: CAMetalDrawable,
        rpd: MTLRenderPassDescriptor,
        pw: Float,
        ph: Float,
        letterboxBg: GhosttyColorRgb,
        contentOffsetY: Float = 0,
        contentActive: Bool = true
    ) {
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(letterboxBg.r) / 255,
            green: Double(letterboxBg.g) / 255,
            blue: Double(letterboxBg.b) / 255,
            alpha: 1
        )
        rpd.colorAttachments[0].storeAction = .store

        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd)
        else {
            abortFrameSlot()
            return
        }

        setFrameUniforms(enc, pw: pw, ph: ph, contentOffsetY: 0)

        if let kitty {
            drawImageQuads(enc, kitty.quads(for: .belowBg))
        }

        let scrolled = min(max(scrolledFgCount, 0), fgCount)
        let fixed = fgCount - scrolled

        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(atlas.texture, index: 0)
        enc.setFragmentTexture(colorAtlas.texture, index: 1)
        enc.setFragmentSamplerState(sampler, index: 0)
        setFrameUniforms(enc, pw: pw, ph: ph, contentOffsetY: contentOffsetY)
        if bgCount > 0 {
            enc.setVertexBuffer(instanceBuffer, offset: 0, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: bgCount)
        }

        if let kitty {
            setFrameUniforms(enc, pw: pw, ph: ph, contentOffsetY: 0)
            drawImageQuads(enc, kitty.quads(for: .belowText))
            setFrameUniforms(enc, pw: pw, ph: ph, contentOffsetY: contentOffsetY)
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentTexture(atlas.texture, index: 0)
            enc.setFragmentTexture(colorAtlas.texture, index: 1)
            enc.setFragmentSamplerState(sampler, index: 0)
        }

        if scrolled > 0 {
            enc.setVertexBuffer(instanceBuffer, offset: bgCount * CellInstance.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: scrolled)
        }

        if fixed > 0 {
            setFrameUniforms(enc, pw: pw, ph: ph, contentOffsetY: 0)
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentTexture(atlas.texture, index: 0)
            enc.setFragmentTexture(colorAtlas.texture, index: 1)
            enc.setFragmentSamplerState(sampler, index: 0)
            let byteOffset = (bgCount + scrolled) * CellInstance.stride
            enc.setVertexBuffer(instanceBuffer, offset: byteOffset, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: fixed)
        }

        if let kitty {
            setFrameUniforms(enc, pw: pw, ph: ph, contentOffsetY: 0)
            drawImageQuads(enc, kitty.quads(for: .aboveText))
        }

        enc.endEncoding()
        presentPaced(cmd, drawable: drawable, contentActive: contentActive)
        cmd.commit()
    }

    /// Draw Kitty image quads in list order, batching only consecutive same-texture runs.
    /// Preserves sort order (z, y, x) across texture changes.
    private func drawImageQuads(
        _ enc: MTLRenderCommandEncoder,
        _ quads: [KittyGraphicsCache.DrawQuad]
    ) {
        guard !quads.isEmpty,
              let imagePipeline,
              let imageSampler
        else { return }

        enc.setRenderPipelineState(imagePipeline)
        enc.setFragmentSamplerState(imageSampler, index: 0)

        var start = 0
        while start < quads.count {
            let tex = quads[start].texture
            var end = start + 1
            while end < quads.count, quads[end].texture === tex {
                end += 1
            }
            let batchCount = end - start
            ensureImageInstanceCapacity(batchCount)
            guard let buf = imageInstanceBuffer else { return }

            let floatsNeeded = batchCount * 8 // ox,oy,sx,sy,u0,v0,u1,v1
            if imageFloatScratch.count < floatsNeeded {
                imageFloatScratch = [Float](repeating: 0, count: floatsNeeded)
            }
            imageFloatScratch.withUnsafeMutableBufferPointer { dest in
                guard let base = dest.baseAddress else { return }
                for i in 0..<batchCount {
                    let q = quads[start + i]
                    let o = i * 8
                    base[o + 0] = q.originX
                    base[o + 1] = q.originY
                    base[o + 2] = q.width
                    base[o + 3] = q.height
                    base[o + 4] = q.u0
                    base[o + 5] = q.v0
                    base[o + 6] = q.u1
                    base[o + 7] = q.v1
                }
                buf.contents().copyMemory(
                    from: base,
                    byteCount: floatsNeeded * MemoryLayout<Float>.size
                )
            }
            enc.setVertexBuffer(buf, offset: 0, index: 0)
            enc.setFragmentTexture(tex, index: 0)
            enc.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: 6,
                instanceCount: batchCount
            )
            start = end
        }
    }

    private func ensureImageInstanceCapacity(_ count: Int) {
        let need = max(count, 1) * 8 * MemoryLayout<Float>.size
        if imageInstanceCapacity >= need, imageInstanceBuffer != nil { return }
        imageInstanceCapacity = need * 2
        imageInstanceBuffer = device.makeBuffer(
            length: imageInstanceCapacity,
            options: .storageModeShared
        )
    }

    /// `present(_:afterMinimumDuration:)` so Adaptive-Sync can hold frames in-range.
    private func presentPaced(
        _ cmd: MTLCommandBuffer,
        drawable: CAMetalDrawable,
        contentActive: Bool
    ) {
        let duration = presentDuration(contentActive: contentActive)
        cmd.present(drawable, afterMinimumDuration: duration)
        let ema = gpuTimeEMA
        let release = frames.takePendingRelease()
        let ring = frames
        cmd.addCompletedHandler { buffer in
            if release { ring.signal() }
            let gpu = buffer.gpuEndTime - buffer.gpuStartTime
            guard gpu > 0, gpu.isFinite else { return }
            let alpha = 0.25
            ema.value = gpu * alpha + ema.value * (1.0 - alpha)
        }
    }

    /// Drop an acquired slot when encode fails before commit.
    func abortFrameSlot() {
        if frames.takePendingRelease() {
            frames.signal()
        }
    }

    /// Single codepoint from the packed cell; UTF-8 only for grapheme clusters.
    func packedCellText(
        _ cells: GhosttyRenderStateRowCells,
        raw: GhosttyCell?
    ) -> (text: String, cp: UInt32) {
        if let raw {
            var tag = GHOSTTY_CELL_CONTENT_CODEPOINT
            if ghostty_cell_get(raw, GHOSTTY_CELL_DATA_CONTENT_TAG, &tag) == GHOSTTY_SUCCESS,
               tag == GHOSTTY_CELL_CONTENT_CODEPOINT {
                var cp: UInt32 = 0
                if ghostty_cell_get(raw, GHOSTTY_CELL_DATA_CODEPOINT, &cp) == GHOSTTY_SUCCESS {
                    if cp == 0 || cp == KittyVirtualUnicode.placeholder {
                        return ("", 0)
                    }
                    // Single scalar: keep cp only. Intern on shaper miss / wide paint.
                    return ("", cp)
                }
            }
        }
        let text = cellTextUTF8(cells) ?? ""
        if let first = text.unicodeScalars.first {
            if first.value == KittyVirtualUnicode.placeholder {
                return ("", 0)
            }
            return (text, first.value)
        }
        return ("", 0)
    }

    func internCodepoint(_ cp: UInt32) -> String {
        if cp == 0 { return "" }
        if let hit = codepointStrings[cp] { return hit }
        guard let scalar = UnicodeScalar(cp) else { return "" }
        let s = String(scalar)
        if codepointStrings.count < 8192 {
            codepointStrings[cp] = s
        }
        return s
    }

    func cellTextUTF8(_ cells: GhosttyRenderStateRowCells) -> String? {
        // Prefer UTF-8. Grow on OUT_OF_SPACE (long ZWJ / combining clusters).
        for _ in 0..<6 {
            var written = 0
            var needed = 0
            if utf8Scratch.count < 16 {
                utf8Scratch = [UInt8](repeating: 0, count: 128)
            }
            let result = utf8Scratch.withUnsafeMutableBufferPointer { buf -> GhosttyResult in
                var gb = GhosttyBuffer(ptr: buf.baseAddress, cap: buf.count, len: 0)
                let r = ghostty_render_state_row_cells_get(
                    cells,
                    GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8,
                    &gb
                )
                written = Int(gb.len)
                needed = Int(gb.len)
                return r
            }
            if result == GHOSTTY_SUCCESS {
                if written <= 0 { return nil }
                return String(bytes: utf8Scratch.prefix(written), encoding: .utf8)
            }
            if result == GHOSTTY_OUT_OF_SPACE {
                utf8Scratch = [UInt8](repeating: 0, count: max(needed, utf8Scratch.count * 2, 1))
                continue
            }
            break
        }

        // Fallback: GRAPHEMES_BUF requires *at least* graphemes_len u32s (no cap check).
        // Capping to 16 overflowed the heap on long unicode clusters (vtebench).
        var graphemeLen: UInt32 = 0
        _ = ghostty_render_state_row_cells_get(
            cells,
            GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN,
            &graphemeLen
        )
        guard graphemeLen > 0 else { return nil }
        let len = Int(graphemeLen)
        // Pathological length (corrupt state): refuse rather than allocate gigabytes.
        guard len <= 4096 else { return nil }
        var codepoints = [UInt32](repeating: 0, count: len)
        codepoints.withUnsafeMutableBufferPointer { buf in
            _ = ghostty_render_state_row_cells_get(
                cells,
                GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF,
                buf.baseAddress
            )
        }
        let scalars = codepoints.compactMap { UnicodeScalar($0) }
        let s = String(String.UnicodeScalarView(scalars))
        return s.isEmpty ? nil : s
    }

    func ensureInstanceCapacity(_ count: Int) {
        if count <= instanceCapacity, instanceBuffer != nil { return }
        let cap = max(count * 2, 1024)
        instanceBuffer = device.makeBuffer(
            length: cap * CellInstance.stride,
            options: .storageModeShared
        )
        instanceCapacity = cap
    }

    func presentClear(drawable: CAMetalDrawable, rpd: MTLRenderPassDescriptor, clearColor: MTLClearColor) {
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = clearColor
        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd)
        else {
            abortFrameSlot()
            return
        }
        enc.endEncoding()
        presentPaced(cmd, drawable: drawable, contentActive: false)
        cmd.commit()
    }

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct CellInstance {
        float2 origin;
        float2 size;
        float4 uv;
        float4 fg;
        float4 bg;
        // Four floats, not float3: MSL float3 is 16-byte aligned (96-byte stride).
        float atlas;
        float pad0;
        float pad1;
        float pad2;
    };

    struct ImageInstance {
        float2 origin;
        float2 size;
        float4 uv; // u0,v0,u1,v1
    };

    struct FrameUniforms {
        float2 viewport;
        float contentOffsetY;
        float _pad;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
        float4 fg;
        float4 bg;
        float hasGlyph;
        float atlas;
    };

    struct ImageVertexOut {
        float4 position [[position]];
        float2 uv;
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
        px.y += uni.contentOffsetY;
        float2 ndc;
        ndc.x = (px.x / uni.viewport.x) * 2.0 - 1.0;
        ndc.y = 1.0 - (px.y / uni.viewport.y) * 2.0;
        VertexOut o;
        o.position = float4(ndc, 0.0, 1.0);
        o.uv = float2(mix(c.uv.x, c.uv.z, corner.x), mix(c.uv.y, c.uv.w, corner.y));
        o.fg = c.fg;
        o.bg = c.bg;
        o.hasGlyph = (c.uv.z > c.uv.x + 1e-6 && c.uv.w > c.uv.y + 1e-6) ? 1.0 : 0.0;
        o.atlas = c.atlas;
        return o;
    }

    fragment float4 cell_fragment(VertexOut in [[stage_in]],
                                  texture2d<float> atlas [[texture(0)]],
                                  texture2d<float> colorAtlas [[texture(1)]],
                                  sampler samp [[sampler(0)]]) {
        float4 bg = in.bg;
        if (in.atlas > 0.5 && in.hasGlyph > 0.5) {
            float4 c = colorAtlas.sample(samp, in.uv);
            if (c.a > 0.001) { c.rgb /= c.a; }
            if (bg.a < 0.01) {
                return float4(c.rgb, saturate(c.a));
            }
            float3 rgb = mix(bg.rgb, c.rgb, saturate(c.a));
            return float4(rgb, 1.0);
        }
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

    vertex ImageVertexOut image_vertex(uint vid [[vertex_id]],
                                       uint iid [[instance_id]],
                                       const device ImageInstance *imgs [[buffer(0)]],
                                       constant FrameUniforms &uni [[buffer(1)]]) {
        ImageInstance c = imgs[iid];
        float2 corner = corners[vid];
        float2 px = c.origin + corner * c.size;
        float2 ndc;
        ndc.x = (px.x / uni.viewport.x) * 2.0 - 1.0;
        ndc.y = 1.0 - (px.y / uni.viewport.y) * 2.0;
        ImageVertexOut o;
        o.position = float4(ndc, 0.0, 1.0);
        o.uv = float2(mix(c.uv.x, c.uv.z, corner.x), mix(c.uv.y, c.uv.w, corner.y));
        return o;
    }

    fragment float4 image_fragment(ImageVertexOut in [[stage_in]],
                                   texture2d<float> tex [[texture(0)]],
                                   sampler samp [[sampler(0)]]) {
        float4 c = tex.sample(samp, in.uv);
        return float4(c.rgb * c.a, c.a); // premultiplied; pipeline source factor = one
    }
    """
}
