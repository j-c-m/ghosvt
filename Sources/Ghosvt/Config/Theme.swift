import CGhosttyVT
import Foundation

/// Ghostty color token: a hex RGB or a live cell color.
enum ThemeColor: Equatable, Sendable {
    case rgb(GhosttyColorRgb)
    case cellForeground
    case cellBackground

    func resolve(
        cellInk: CellPaintColors.RGB,
        cellFill: CellPaintColors.RGB,
        defFg: GhosttyColorRgb,
        defBg: GhosttyColorRgb
    ) -> CellPaintColors.RGB {
        switch self {
        case .rgb(let c):
            return CellPaintColors.RGB(c)
        case .cellForeground:
            return cellInk
        case .cellBackground:
            return cellFill
        }
    }
}

/// Host theme after `theme =` file plus explicit config overlays.
struct ResolvedTheme: Equatable, Sendable {
    var foreground: GhosttyColorRgb
    var background: GhosttyColorRgb
    var palette: [GhosttyColorRgb]
    var cursorColor: ThemeColor
    var cursorText: ThemeColor
    var selectionForeground: ThemeColor
    var selectionBackground: ThemeColor
    var searchForeground: ThemeColor
    var searchBackground: ThemeColor
    var searchSelectedForeground: ThemeColor
    var searchSelectedBackground: ThemeColor

    static func fallback() -> ResolvedTheme {
        var palette = [GhosttyColorRgb](repeating: GhosttyColorRgb(r: 0, g: 0, b: 0), count: 256)
        for (i, c) in DefaultColors.ansi16.enumerated() {
            palette[i] = c
        }
        return ResolvedTheme(
            foreground: DefaultColors.foreground,
            background: DefaultColors.background,
            palette: palette,
            cursorColor: .cellForeground,
            cursorText: .cellBackground,
            selectionForeground: .cellBackground,
            selectionBackground: .cellForeground,
            searchForeground: .rgb(GhosttyColorRgb(r: 0x00, g: 0x00, b: 0x00)),
            searchBackground: .rgb(GhosttyColorRgb(r: 0xFF, g: 0xE0, b: 0x82)),
            searchSelectedForeground: .rgb(GhosttyColorRgb(r: 0x00, g: 0x00, b: 0x00)),
            searchSelectedBackground: .rgb(GhosttyColorRgb(r: 0xF2, g: 0xA5, b: 0x7E))
        )
    }
}

enum Theme {
    nonisolated(unsafe) static var current = ResolvedTheme.fallback()

    static func resolve(from config: Config) -> ResolvedTheme {
        var theme = ResolvedTheme.fallback()
        if !config.themeName.isEmpty {
            if let url = lookupFile(name: config.themeName) {
                apply(parse(contentsOf: url), to: &theme)
            } else {
                fputs("ghosvt: theme not found: \(config.themeName)\n", stderr)
            }
        }
        apply(config.themeOverlay, to: &theme)
        current = theme
        return theme
    }

    static func lookupFile(name: String) -> URL? {
        let slug = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !slug.isEmpty, !slug.contains("/"), !slug.contains("\\") else { return nil }
        var dirs: [URL] = [
            Config.configDirectoryURL().appendingPathComponent("themes", isDirectory: true),
        ]
        // App Resources, SPM resource bundle (when present), then source tree.
        let bundles: [URL?] = [
            Bundle.main.url(forResource: "themes", withExtension: nil),
            Bundle.main.url(forResource: "themes", withExtension: nil, subdirectory: "Resources"),
            Bundle.main.resourceURL?.appendingPathComponent("themes", isDirectory: true),
            Bundle.main.resourceURL?.appendingPathComponent("Resources/themes", isDirectory: true),
        ]
        dirs.append(contentsOf: bundles.compactMap { $0 })
        #if SWIFT_PACKAGE
        let module: [URL?] = [
            Bundle.module.url(forResource: "themes", withExtension: nil, subdirectory: "Resources"),
            Bundle.module.url(forResource: "themes", withExtension: nil),
            Bundle.module.resourceURL?.appendingPathComponent("Resources/themes", isDirectory: true),
            Bundle.module.resourceURL?.appendingPathComponent("themes", isDirectory: true),
        ]
        dirs.append(contentsOf: module.compactMap { $0 })
        #endif
        dirs.append(
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/themes", isDirectory: true)
        )
        let fm = FileManager.default
        for dir in dirs {
            let url = dir.appendingPathComponent(slug)
            if fm.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    struct Overlay: Equatable, Sendable {
        var background: ThemeColor?
        var foreground: ThemeColor?
        var cursorColor: ThemeColor?
        var cursorText: ThemeColor?
        var selectionForeground: ThemeColor?
        var selectionBackground: ThemeColor?
        var searchForeground: ThemeColor?
        var searchBackground: ThemeColor?
        var searchSelectedForeground: ThemeColor?
        var searchSelectedBackground: ThemeColor?
        var palette: [Int: GhosttyColorRgb] = [:]
    }

    static func parse(contentsOf url: URL) -> Overlay {
        guard let data = try? String(contentsOf: url, encoding: .utf8) else {
            return Overlay()
        }
        return parse(text: data)
    }

    static func parse(text: String) -> Overlay {
        var out = Overlay()
        for rawLine in text.split(whereSeparator: \.isNewline) {
            guard let kv = Config.parseAssignment(String(rawLine)) else { continue }
            apply(kv.key, value: kv.value, to: &out)
        }
        return out
    }

    static func apply(_ key: String, value: String, to overlay: inout Overlay) {
        switch key {
        case "background":
            if let c = parseColor(value) { overlay.background = c }
        case "foreground":
            if let c = parseColor(value) { overlay.foreground = c }
        case "cursor-color":
            if let c = parseColor(value) { overlay.cursorColor = c }
        case "cursor-text":
            if let c = parseColor(value) { overlay.cursorText = c }
        case "selection-foreground":
            if let c = parseColor(value) { overlay.selectionForeground = c }
        case "selection-background":
            if let c = parseColor(value) { overlay.selectionBackground = c }
        case "search-foreground":
            if let c = parseColor(value) { overlay.searchForeground = c }
        case "search-background":
            if let c = parseColor(value) { overlay.searchBackground = c }
        case "search-selected-foreground":
            if let c = parseColor(value) { overlay.searchSelectedForeground = c }
        case "search-selected-background":
            if let c = parseColor(value) { overlay.searchSelectedBackground = c }
        case "palette":
            if let pair = parsePalette(value) {
                overlay.palette[pair.index] = pair.color
            }
        default:
            break
        }
    }

    static func apply(_ overlay: Overlay, to theme: inout ResolvedTheme) {
        if case .rgb(let c) = overlay.background { theme.background = c }
        if case .rgb(let c) = overlay.foreground { theme.foreground = c }
        if let c = overlay.cursorColor { theme.cursorColor = c }
        if let c = overlay.cursorText { theme.cursorText = c }
        if let c = overlay.selectionForeground { theme.selectionForeground = c }
        if let c = overlay.selectionBackground { theme.selectionBackground = c }
        if let c = overlay.searchForeground { theme.searchForeground = c }
        if let c = overlay.searchBackground { theme.searchBackground = c }
        if let c = overlay.searchSelectedForeground { theme.searchSelectedForeground = c }
        if let c = overlay.searchSelectedBackground { theme.searchSelectedBackground = c }
        for (i, c) in overlay.palette where i >= 0 && i < theme.palette.count {
            theme.palette[i] = c
        }
    }

    static func parseColor(_ value: String) -> ThemeColor? {
        switch value.lowercased() {
        case "cell-foreground":
            return .cellForeground
        case "cell-background":
            return .cellBackground
        default:
            if let rgb = parseHex(value) { return .rgb(rgb) }
            return nil
        }
    }

    static func parseHex(_ value: String) -> GhosttyColorRgb? {
        var s = value.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let n = UInt32(s, radix: 16) else { return nil }
        return GhosttyColorRgb(
            r: UInt8((n >> 16) & 0xFF),
            g: UInt8((n >> 8) & 0xFF),
            b: UInt8(n & 0xFF)
        )
    }

    static func parsePalette(_ value: String) -> (index: Int, color: GhosttyColorRgb)? {
        guard let eq = value.firstIndex(of: "=") else { return nil }
        let nstr = value[..<eq].trimmingCharacters(in: .whitespaces)
        let cstr = value[value.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        guard let n = Int(nstr), n >= 0, n <= 255, let rgb = parseHex(cstr) else {
            return nil
        }
        return (n, rgb)
    }
}

extension GhosttyColorRgb: @retroactive Equatable {
    public static func == (lhs: GhosttyColorRgb, rhs: GhosttyColorRgb) -> Bool {
        lhs.r == rhs.r && lhs.g == rhs.g && lhs.b == rhs.b
    }
}
