import CoreFoundation
import CoreText
import Foundation

/// JetBrains Mono + Symbols Nerd Font, bundled the same way Ghostty embeds them.
///
/// Sources (Ghostty dependency pins):
/// - `https://deps.files.ghostty.org/JetBrainsMono-2.304.tar.gz`
/// - `https://deps.files.ghostty.org/NerdFontsSymbolsOnly-3.4.0.tar.gz`
///
/// JetBrains Mono faces from the Ghostty CDN package, plus Symbols Nerd Font.
/// Terminal SGR bold uses **ExtraBold** (heavier than Bold at small sizes).
enum EmbeddedFonts {
    enum Face: String, CaseIterable {
        case regular = "JetBrainsMono-Regular.ttf"
        case bold = "JetBrainsMono-Bold.ttf"
        case italic = "JetBrainsMono-Italic.ttf"
        case boldItalic = "JetBrainsMono-BoldItalic.ttf"
        case extraBold = "JetBrainsMono-ExtraBold.ttf"
        case extraBoldItalic = "JetBrainsMono-ExtraBoldItalic.ttf"
        case variable = "JetBrainsMono-Variable.ttf"
        case variableItalic = "JetBrainsMono-Italic-Variable.ttf"
        /// Ghostty `nerd_fonts_symbols_only` (`SymbolsNerdFont-Regular.ttf`).
        case symbolsNerd = "SymbolsNerdFont-Regular.ttf"
        /// Mono symbols (tighter cell fit for terminal glyphs).
        case symbolsNerdMono = "SymbolsNerdFontMono-Regular.ttf"
    }

    /// Mutable cache held behind a lock (avoids Swift 6 global mutable static warnings).
    private final class Store: @unchecked Sendable {
        let lock = NSLock()
        var dataProviders: [Face: CGDataProvider] = [:]
        var fontCache: [String: CTFont] = [:]
    }

    private static let store = Store()

    /// Primary monospace face cascaded with Nerd Font symbol faces.
    static func primary(size: CGFloat, bold: Bool = false, italic: Bool = false) -> CTFont {
        store.lock.lock()
        defer { store.lock.unlock() }

        let key = "primary-\(size)-\(bold)-\(italic)"
        if let cached = store.fontCache[key] {
            return cached
        }

        // Prefer ExtraBold for SGR bold; fall back to Bold if a face is missing.
        let candidates: [Face]
        switch (bold, italic) {
        case (true, true): candidates = [.extraBoldItalic, .boldItalic]
        case (true, false): candidates = [.extraBold, .bold]
        case (false, true): candidates = [.italic]
        case (false, false): candidates = [.regular]
        }

        var base: CTFont?
        for face in candidates {
            if let font = makeFontUnlocked(face: face, size: size) {
                base = font
                break
            }
        }
        guard let base else {
            let fallback = CTFontCreateWithName("Menlo" as CFString, size, nil)
            store.fontCache[key] = fallback
            return fallback
        }

        // Return the face font directly (no cascade descriptor merge).
        // Merging kCTFontCascadeListAttribute produced CTFonts that CTLineDraw
        // rasterized as inverted/garbled glyphs for JetBrains Mono.
        // Nerd symbols are tried per-glyph via GlyphAtlas fallbackFonts.
        store.fontCache[key] = base
        return base
    }

    /// Symbols Nerd Font Mono — used as per-glyph atlas fallback only.
    /// Returns nil if the face is not embedded (do not silently use Menlo).
    static func primaryNerdMono(size: CGFloat) -> CTFont? {
        store.lock.lock()
        defer { store.lock.unlock() }
        let key = "nerd-mono-\(size)"
        if let cached = store.fontCache[key] { return cached }
        guard let font = makeFontUnlocked(face: .symbolsNerdMono, size: size) else {
            fputs("ghosvt: SymbolsNerdFontMono missing at size \(size)\n", stderr)
            return nil
        }
        store.fontCache[key] = font
        return font
    }

    /// Symbols Nerd Font (proportional) — second atlas fallback.
    static func primaryNerd(size: CGFloat) -> CTFont? {
        store.lock.lock()
        defer { store.lock.unlock() }
        let key = "nerd-\(size)"
        if let cached = store.fontCache[key] { return cached }
        guard let font = makeFontUnlocked(face: .symbolsNerd, size: size) else {
            fputs("ghosvt: SymbolsNerdFont missing at size \(size)\n", stderr)
            return nil
        }
        store.fontCache[key] = font
        return font
    }

    /// Nerd faces at `size` (mono first). Omits faces that failed to load.
    static func nerdFaces(size: CGFloat) -> [CTFont] {
        [primaryNerdMono(size: size), primaryNerd(size: size)].compactMap { $0 }
    }

    /// Touch all font files so missing assets fail at startup, not mid-frame.
    static func preload() {
        store.lock.lock()
        defer { store.lock.unlock() }
        for face in Face.allCases {
            if loadProviderUnlocked(face) == nil {
                fputs("ghosvt: embedded font missing: \(face.rawValue)\n", stderr)
            }
        }
    }

    // MARK: - Private

    private static func makeFontUnlocked(face: Face, size: CGFloat) -> CTFont? {
        let key = "raw-\(face.rawValue)-\(size)"
        if let cached = store.fontCache[key] {
            return cached
        }
        guard let provider = loadProviderUnlocked(face) else { return nil }
        guard let cgFont = CGFont(provider) else { return nil }
        let font = CTFontCreateWithGraphicsFont(cgFont, size, nil, nil)
        store.fontCache[key] = font
        return font
    }

    private static func loadProviderUnlocked(_ face: Face) -> CGDataProvider? {
        if let existing = store.dataProviders[face] {
            return existing
        }
        guard let url = resourceURL(for: face) else {
            return nil
        }
        guard let provider = CGDataProvider(url: url as CFURL) else {
            return nil
        }
        store.dataProviders[face] = provider
        return provider
    }

    private static func resourceURL(for face: Face) -> URL? {
        let name = (face.rawValue as NSString).deletingPathExtension
        let ext = (face.rawValue as NSString).pathExtension

        // SPM Bundle.module with `.copy("Resources")` → Resources/Fonts/…
        if let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fonts") {
            return url
        }
        if let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Resources/Fonts") {
            return url
        }
        if let url = Bundle.module.url(forResource: face.rawValue, withExtension: nil) {
            return url
        }

        // Source-tree fallback (debug without resource bundle).
        let dev = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Fonts/\(face.rawValue)")
        if FileManager.default.fileExists(atPath: dev.path) {
            return dev
        }
        return nil
    }
}
