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

    func present(
        count: Int,
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

        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(instanceBuffer, offset: 0, index: 0)
        enc.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
        enc.setFragmentTexture(atlas.texture, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)

        if count > 0 {
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: count)
        }

        enc.endEncoding()
        presentPaced(cmd, drawable: drawable, contentActive: contentActive)
        cmd.commit()
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
