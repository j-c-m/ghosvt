import CoreText
import Foundation

/// Ghostty-style system font discovery for missing codepoints.
///
/// When the primary mono face and explicit fallbacks (Nerd, …) do not map a
/// character, ask Core Text for a face that can (`CTFontCreateForString`), the
/// same API Ghostty uses in `font/discovery.zig` `discoverCodepoint`.
///
/// Results are cached (including negative hits). LastResort is rejected.
enum SystemFontFallback {
    private final class Store: @unchecked Sendable {
        let lock = NSLock()
        /// `nil` value = known miss (do not re-query).
        var byKey: [Key: CTFont?] = [:]
    }

    private struct Key: Hashable {
        let text: String
        let sizeMilli: Int
        let basePS: String
    }

    private static let store = Store()

    /// Face that covers `text`, discovered from `primary`'s cascade, or nil.
    ///
    /// Returns nil when `primary` already covers `text` (caller should use
    /// primary), when Core Text only offers LastResort, or when no face maps
    /// the string.
    static func face(for text: String, from primary: CTFont) -> CTFont? {
        guard !text.isEmpty else { return nil }
        // Caller already tried primary; still skip if it covers (cheap).
        if GlyphAtlas.fontCovers(primary, text: text) { return nil }

        let size = CTFontGetSize(primary)
        let basePS = (CTFontCopyPostScriptName(primary) as String?) ?? ""
        let key = Key(
            text: text,
            sizeMilli: Int((size * 1000).rounded()),
            basePS: basePS
        )

        store.lock.lock()
        if let cached = store.byKey[key] {
            store.lock.unlock()
            return cached
        }
        store.lock.unlock()

        let found = discover(text: text, primary: primary)

        store.lock.lock()
        store.byKey[key] = found
        store.lock.unlock()
        return found
    }

    /// Append discovered faces for `text` after explicit `fallbackFonts`.
    /// Dedupes by PostScript name.
    static func fonts(
        for text: String,
        primary: CTFont,
        already: [CTFont]
    ) -> [CTFont] {
        guard let sys = face(for: text, from: primary) else { return [] }
        let sysPS = (CTFontCopyPostScriptName(sys) as String?) ?? ""
        let known = Set(
            ([primary] + already).compactMap { CTFontCopyPostScriptName($0) as String? }
        )
        if known.contains(sysPS) { return [] }
        return [sys]
    }

    // MARK: - Private

    private static func discover(text: String, primary: CTFont) -> CTFont? {
        let cfStr = text as CFString
        let len = CFStringGetLength(cfStr)
        guard len > 0 else { return nil }
        // UTF-16 unit range (surrogate pairs for non-BMP), matching Ghostty.
        let range = CFRange(location: 0, length: len)
        let candidate = CTFontCreateForString(primary, cfStr, range)

        let ps = (CTFontCopyPostScriptName(candidate) as String?) ?? ""
        // Core Text's last-ditch face only has replacement glyphs — Ghostty skips it.
        if ps == "LastResort" || ps.hasSuffix("LastResort") {
            return nil
        }

        // Must map every scalar (CreateForString can still return a weak face).
        guard GlyphAtlas.fontCovers(candidate, text: text) else {
            return nil
        }

        // Same face as primary and we already know primary lacks coverage.
        let primaryPS = (CTFontCopyPostScriptName(primary) as String?) ?? ""
        if ps == primaryPS {
            return nil
        }

        // Normalize to the requested point size (cascade face may differ).
        let want = CTFontGetSize(primary)
        if abs(CTFontGetSize(candidate) - want) > 0.01 {
            let desc = CTFontCopyFontDescriptor(candidate)
            return CTFontCreateWithFontDescriptor(desc, want, nil)
        }
        return candidate
    }
}
