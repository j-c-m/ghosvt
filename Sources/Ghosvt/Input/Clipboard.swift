import AppKit
import CGhosttyVT
import Foundation

/// System pasteboard helpers for host copy/paste and OSC 52 writes.
enum Clipboard {
    static func copyString(_ text: String) {
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    static func pasteString() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    /// Apply an OSC 52 / clipboard-write effect to the general pasteboard.
    static func applyClipboardWrite(_ write: GhosttyClipboardWrite) -> GhosttyClipboardWriteResult {
        // Map selection/primary to the same general pasteboard on macOS.
        switch write.location {
        case GHOSTTY_CLIPBOARD_LOCATION_STANDARD,
             GHOSTTY_CLIPBOARD_LOCATION_SELECTION,
             GHOSTTY_CLIPBOARD_LOCATION_PRIMARY:
            break
        default:
            return GHOSTTY_CLIPBOARD_WRITE_RESULT_UNSUPPORTED
        }

        if write.contents_len == 0 {
            NSPasteboard.general.clearContents()
            return GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS
        }

        guard let contents = write.contents else {
            return GHOSTTY_CLIPBOARD_WRITE_RESULT_INVALID_DATA
        }

        // Prefer text/plain; otherwise first UTF-8-looking payload.
        var chosen: String?
        for i in 0..<write.contents_len {
            let c = contents.advanced(by: i).pointee
            let mime = ghosttyStringToString(c.mime) ?? ""
            let data = ghosttyStringToData(c.data)
            if mime.hasPrefix("text/plain") || mime.isEmpty {
                if let s = String(data: data, encoding: .utf8) {
                    chosen = s
                    break
                }
            }
            if chosen == nil, let s = String(data: data, encoding: .utf8) {
                chosen = s
            }
        }

        guard let text = chosen else {
            return GHOSTTY_CLIPBOARD_WRITE_RESULT_UNSUPPORTED
        }
        copyString(text)
        return GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS
    }

    private static func ghosttyStringToString(_ s: GhosttyString) -> String? {
        guard let ptr = s.ptr else { return s.len == 0 ? "" : nil }
        if s.len == 0 { return "" }
        return String(bytes: UnsafeBufferPointer(start: ptr, count: s.len), encoding: .utf8)
    }

    private static func ghosttyStringToData(_ s: GhosttyString) -> Data {
        guard let ptr = s.ptr, s.len > 0 else { return Data() }
        return Data(bytes: ptr, count: s.len)
    }
}
