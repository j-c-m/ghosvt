import CGhosttyVT
import Foundation
import Metal
import MetalKit
import QuartzCore

// MARK: - GPU
extension TerminalRenderer {
    func uploadInstances(_ instances: [CellInstance]) {
        // Merge underlines that were collected into underlineExtras already appended by caller.
        let count = instances.count
        ensureInstanceCapacity(max(count, 1))
        guard count > 0, let buf = instanceBuffer else {
            lastDrawnCount = 0
            lastBgCount = 0
            lastFgCount = 0
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
    /// Instance buffer layout: `[0 .. bgCount) backgrounds | [bgCount ..) glyphs+overlays`.
    /// Draw order:
    ///   1. below_bg images
    ///   2. cell backgrounds
    ///   3. below_text images
    ///   4. glyphs + cursor + search HUD
    ///   5. above_text images
    func present(
        bgCount: Int,
        fgCount: Int,
        kitty: KittyGraphicsCache?,
        drawable: CAMetalDrawable,
        rpd: MTLRenderPassDescriptor,
        pw: Float,
        ph: Float,
        letterboxBg: GhosttyColorRgb,
        contentActive: Bool = true
    ) {
        if let ub = uniformBuffer {
            var uni = FrameUniforms(viewportX: pw, viewportY: ph)
            withUnsafeBytes(of: &uni) { raw in
                ub.contents().copyMemory(from: raw.baseAddress!, byteCount: FrameUniforms.stride)
            }
        }

        // Clear the full drawable so max-aspect letterbox bars match the TUI/terminal bg.
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
        else { return }

        enc.setVertexBuffer(uniformBuffer, offset: 0, index: 1)

        if let kitty {
            drawImageQuads(enc, kitty.quads(for: .belowBg))
        }

        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(instanceBuffer, offset: 0, index: 0)
        enc.setFragmentTexture(atlas.texture, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        if bgCount > 0 {
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: bgCount)
        }

        if let kitty {
            drawImageQuads(enc, kitty.quads(for: .belowText))
        }

        // Glyph/overlay instances are packed after backgrounds.
        if fgCount > 0 {
            enc.setRenderPipelineState(pipeline)
            let byteOffset = bgCount * CellInstance.stride
            enc.setVertexBuffer(instanceBuffer, offset: byteOffset, index: 0)
            enc.setFragmentTexture(atlas.texture, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: fgCount)
        }

        if let kitty {
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
        // WWDC21: EMA of GPU time drives the next active frame’s minimum duration.
        let ema = gpuTimeEMA
        cmd.addCompletedHandler { buffer in
            let gpu = buffer.gpuEndTime - buffer.gpuStartTime
            guard gpu > 0, gpu.isFinite else { return }
            let alpha = 0.25
            ema.value = gpu * alpha + ema.value * (1.0 - alpha)
        }
    }

    func cellTextUTF8(_ cells: GhosttyRenderStateRowCells) -> String? {
        // Prefer UTF-8. Grow on OUT_OF_SPACE (long ZWJ / combining clusters).
        var cap = 128
        for _ in 0..<6 {
            var storage = [UInt8](repeating: 0, count: cap)
            var written = 0
            var needed = 0
            let result = storage.withUnsafeMutableBufferPointer { buf -> GhosttyResult in
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
                return String(bytes: storage.prefix(written), encoding: .utf8)
            }
            if result == GHOSTTY_OUT_OF_SPACE {
                cap = max(needed, cap * 2, 1)
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
        else { return }
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
    };

    struct ImageInstance {
        float2 origin;
        float2 size;
        float4 uv; // u0,v0,u1,v1
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
