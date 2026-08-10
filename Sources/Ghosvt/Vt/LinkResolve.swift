import CGhosttyVT
import Foundation

/// Resolve a clickable URL at a viewport cell (OSC 8, then bare http(s)).
enum LinkResolve {
    struct Hit: Equatable {
        var url: URL
        /// Inclusive column range in the row (viewport / shell coords).
        var startCol: Int
        var endCol: Int
    }

    /// Sanitize with Ghostty’s UntrustedURL policy; embed only allows http/https.
    static func embeddableURL(from raw: String) -> URL? {
        UntrustedURL(raw.trimmingCharacters(in: .whitespacesAndNewlines)).embeddableHTTPURL
    }

    /// OSC 8 hyperlink URI at viewport (col, row), if any.
    static func osc8URI(
        terminal: GhosttyTerminal,
        col: UInt16,
        row: UInt16
    ) -> String? {
        var ref = GhosttyGridRef()
        ref.size = MemoryLayout<GhosttyGridRef>.size
        var point = GhosttyPoint()
        point.tag = GHOSTTY_POINT_TAG_VIEWPORT
        point.value.coordinate.x = col
        point.value.coordinate.y = UInt32(row)
        guard ghostty_terminal_grid_ref(terminal, point, &ref) == GHOSTTY_SUCCESS else {
            return nil
        }
        var len: Int = 0
        let probe = ghostty_grid_ref_hyperlink_uri(&ref, nil, 0, &len)
        guard probe == GHOSTTY_OUT_OF_SPACE || (probe == GHOSTTY_SUCCESS && len > 0) else {
            return nil
        }
        guard len > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: len)
        let r = buf.withUnsafeMutableBufferPointer { ptr in
            ghostty_grid_ref_hyperlink_uri(&ref, ptr.baseAddress, ptr.count, &len)
        }
        guard r == GHOSTTY_SUCCESS, len > 0 else { return nil }
        return String(bytes: buf.prefix(len), encoding: .utf8)
    }

    /// Expand an OSC 8 hit to contiguous cells sharing the same URI on `row`.
    static func osc8Span(
        terminal: GhosttyTerminal,
        col: Int,
        row: UInt16,
        cols: Int,
        uri: String
    ) -> (start: Int, end: Int) {
        var lo = col
        var hi = col
        while lo > 0 {
            if osc8URI(terminal: terminal, col: UInt16(lo - 1), row: row) == uri {
                lo -= 1
            } else { break }
        }
        while hi + 1 < cols {
            if osc8URI(terminal: terminal, col: UInt16(hi + 1), row: row) == uri {
                hi += 1
            } else { break }
        }
        return (lo, hi)
    }

    /// Bare `http(s)` under `col` with inclusive column span.
    static func bareHTTPHit(in cells: [String], atCol col: Int) -> (raw: String, start: Int, end: Int)? {
        guard col >= 0, col < cells.count else { return nil }
        var flat = ""
        var colOfIndex: [Int] = []
        flat.reserveCapacity(cells.count * 4)
        colOfIndex.reserveCapacity(cells.count * 4)
        for (c, text) in cells.enumerated() {
            if text.isEmpty {
                flat.append(" ")
                colOfIndex.append(c)
            } else {
                for ch in text {
                    flat.append(ch)
                    colOfIndex.append(c)
                }
            }
        }
        guard !flat.isEmpty else { return nil }
        guard let hit = colOfIndex.firstIndex(of: col) else { return nil }

        let lower = flat.lowercased()
        let markers = ["https://", "http://"]
        var start: String.Index?
        var markerLen = 0
        for m in markers {
            var search = lower.startIndex
            while search < lower.endIndex,
                  let r = lower.range(of: m, range: search..<lower.endIndex) {
                let startOffset = lower.distance(from: lower.startIndex, to: r.lowerBound)
                if hit >= startOffset {
                    let s = flat.index(flat.startIndex, offsetBy: startOffset)
                    if start == nil || s > start! {
                        start = s
                        markerLen = m.count
                    }
                }
                search = r.upperBound
            }
        }
        guard let urlStart = start else { return nil }

        var end = flat.index(urlStart, offsetBy: markerLen, limitedBy: flat.endIndex) ?? flat.endIndex
        let stopScalars: Set<Unicode.Scalar> = [
            " ", "\t", "\n", "\r",
            "<", ">", "\"", "'", "`",
            "(", ")", "[", "]", "{", "}",
            "|", "\\", "^",
        ]
        while end < flat.endIndex {
            let s = flat[end].unicodeScalars.first!
            if stopScalars.contains(s) { break }
            end = flat.index(after: end)
        }
        while end > urlStart {
            let prev = flat.index(before: end)
            if ".,;:!?".contains(flat[prev]) {
                end = prev
            } else {
                break
            }
        }
        let startOffset = flat.distance(from: flat.startIndex, to: urlStart)
        let endOffset = flat.distance(from: flat.startIndex, to: end)
        guard hit >= startOffset, hit < endOffset else { return nil }
        let raw = String(flat[urlStart..<end])
        guard !raw.isEmpty else { return nil }
        let startCol = colOfIndex[startOffset]
        let endCol = colOfIndex[max(startOffset, endOffset - 1)]
        return (raw, startCol, endCol)
    }
}
