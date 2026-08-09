import Foundation

/// User configuration from `~/.config/ghosvt/config` (Ghostty-style key = value).
struct Config: Sendable {
    var vtCount: Int = 6
    var fontSize: CGFloat = 16
    var scrollbackLines: Int = 10_000
    /// Max content width/height (e.g. 1.5 for 3:2). Wider screens letterbox.
    var maxAspect: CGFloat = 3.0 / 2.0
    var scrollSpringK: Double = 120
    var scrollSpringC: Double = 14
    var scrollFriction: Double = 6
    /// When true, mouse-up copies the selection to the pasteboard automatically.
    var copyOnSelect: Bool = false

    static func configDirectoryURL() -> URL {
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg, isDirectory: true).appendingPathComponent("ghosvt", isDirectory: true)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/ghosvt", isDirectory: true)
    }

    static func configFileURL() -> URL {
        configDirectoryURL().appendingPathComponent("config", isDirectory: false)
    }

    static func load() -> Config {
        var cfg = Config()
        let url = configFileURL()
        guard let data = try? String(contentsOf: url, encoding: .utf8) else {
            return cfg
        }
        for rawLine in data.split(whereSeparator: \.isNewline) {
            var line = String(rawLine)
            if let hash = line.firstIndex(of: "#") {
                line = String(line[..<hash])
            }
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "vt-count":
                if let n = Int(value) { cfg.vtCount = min(12, max(1, n)) }
            case "font-size":
                if let n = Double(value) { cfg.fontSize = CGFloat(n) }
            case "scrollback-lines":
                if let n = Int(value) { cfg.scrollbackLines = max(0, n) }
            case "max-aspect", "max-aspect-ratio":
                if let aspect = parseAspect(value) {
                    cfg.maxAspect = aspect
                }
            case "scroll-spring-k":
                if let n = Double(value) { cfg.scrollSpringK = n }
            case "scroll-spring-c":
                if let n = Double(value) { cfg.scrollSpringC = n }
            case "scroll-friction":
                if let n = Double(value) { cfg.scrollFriction = n }
            case "copy-on-select":
                cfg.copyOnSelect = parseBool(value)
            default:
                break
            }
        }
        return cfg
    }

    private static func parseBool(_ value: String) -> Bool {
        switch value.lowercased() {
        case "1", "true", "yes", "on": return true
        default: return false
        }
    }

    /// Parse `3:2`, `3/2`, or a plain float `1.5`. Clamped to a sane range.
    private static func parseAspect(_ value: String) -> CGFloat? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let parts: [Substring]
        if trimmed.contains(":") {
            parts = trimmed.split(separator: ":", maxSplits: 1)
        } else if trimmed.contains("/") {
            parts = trimmed.split(separator: "/", maxSplits: 1)
        } else {
            parts = []
        }
        let ratio: Double?
        if parts.count == 2,
           let w = Double(parts[0].trimmingCharacters(in: .whitespaces)),
           let h = Double(parts[1].trimmingCharacters(in: .whitespaces)),
           w > 0, h > 0 {
            ratio = w / h
        } else {
            ratio = Double(trimmed)
        }
        guard let r = ratio, r.isFinite, r > 0 else { return nil }
        // Avoid absurd values (e.g. 0.01 or 100).
        return CGFloat(min(8.0, max(0.5, r)))
    }
}
