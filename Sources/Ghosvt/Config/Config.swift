import Foundation

/// How each VT is spawned (`console-mode`).
enum ConsoleMode: String, Sendable {
    /// Banner + `/usr/bin/login -p` (getty-style).
    case login
    /// Ghostty-style: `login -flp` → login shell ("Last login: …"); no getty banner.
    case shell
}

/// Where the stolen search row sits (`search-position`).
enum SearchPosition: String, Sendable {
    case top
    case bottom
}

/// User configuration from `~/.config/ghosvt/config` (Ghostty-style key = value).
struct Config: Sendable {
    var vtCount: Int = 6
    var fontSize: CGFloat = 18
    /// Scrollback cap in bytes (Ghostty `scrollback-limit` / `scrollback-limit-bytes`).
    /// Default 50 MB matches Ghostty. Zero disables scrollback.
    var scrollbackLimitBytes: Int = 50_000_000
    /// Max content width/height (e.g. 1.5 for 3:2). Wider screens letterbox.
    var maxAspect: CGFloat = 3.0 / 2.0
    var scrollSpringK: Double = 120
    var scrollSpringC: Double = 14
    var scrollFriction: Double = 6
    /// When true, mouse-up copies the selection to the pasteboard automatically.
    var copyOnSelect: Bool = true
    /// Enable OpenType liga/calt on shaped runs (JetBrains Mono programming ligatures).
    var fontLigatures: Bool = true
    /// When to jump the viewport to the bottom (Ghostty `scroll-to-bottom`).
    /// Default: keystroke on, output off (`keystroke, no-output`).
    var scrollToBottomKeystroke: Bool = true
    var scrollToBottomOutput: Bool = false
    /// Per-VT spawn: `login` (default) or `shell`.
    var consoleMode: ConsoleMode = .login
    /// Getty banner hostname (`login` mode). Nil/empty → system `gethostname`.
    var bannerHostname: String?
    /// Getty banner tty field: true = PTY slave name (default); false = fake `ttyvN`.
    var bannerRealTty: Bool = true
    /// Stolen search row: `top` or `bottom` (default).
    var searchPosition: SearchPosition = .bottom
    /// When true, ⌘B / ⌘-click use the embedded WKWebView. When false, ⌘B is off and ⌘-click uses the system browser.
    var embeddedBrowser: Bool = true
    /// Remote zip/xpi pins loaded on first browser open. Empty = no extensions.
    var webExtensions: [WebExtensionPin] = []

    /// One `web-extension =` line. `spoofFirefoxUA` nil means infer from the manifest.
    struct WebExtensionPin: Sendable, Equatable {
        var url: URL
        var spoofFirefoxUA: Bool?
        static let maxCount = 16
    }

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
            case "scrollback-limit", "scrollback-limit-bytes":
                // Ghostty: `scrollback-limit` is a compat alias for bytes.
                if value.lowercased() == "unlimited" {
                    cfg.scrollbackLimitBytes = Int.max
                } else if let n = Int(value) {
                    cfg.scrollbackLimitBytes = max(0, n)
                }
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
            case "font-ligatures", "ligatures":
                cfg.fontLigatures = parseBool(value)
            case "scroll-to-bottom":
                applyScrollToBottom(value, to: &cfg)
            case "console-mode":
                switch value.lowercased() {
                case "login", "getty":
                    cfg.consoleMode = .login
                case "shell":
                    cfg.consoleMode = .shell
                default:
                    break
                }
            case "banner-hostname":
                // Empty clears override (system hostname).
                let t = value.trimmingCharacters(in: .whitespaces)
                cfg.bannerHostname = t.isEmpty ? nil : t
            case "banner-tty":
                switch value.lowercased() {
                case "fake", "virtual", "ttyv":
                    cfg.bannerRealTty = false
                case "real", "device", "pty":
                    cfg.bannerRealTty = true
                default:
                    break
                }
            case "search-position":
                switch value.lowercased() {
                case "top":
                    cfg.searchPosition = .top
                case "bottom":
                    cfg.searchPosition = .bottom
                default:
                    break
                }
            case "embedded-browser":
                cfg.embeddedBrowser = parseBool(value)
            case "web-extension":
                if cfg.webExtensions.count < WebExtensionPin.maxCount,
                   let pin = parseWebExtension(value) {
                    cfg.webExtensions.append(pin)
                }
            default:
                break
            }
        }
        return cfg
    }

    /// `https://…/pkg.zip` plus optional `firefox-ua` / `safari-ua`.
    private static func parseWebExtension(_ value: String) -> WebExtensionPin? {
        let parts = value.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let raw = parts.first, let url = UntrustedURL(raw).embeddableHTTPURL else {
            return nil
        }
        var spoof: Bool?
        for token in parts.dropFirst() {
            switch token.lowercased() {
            case "firefox-ua", "firefox":
                spoof = true
            case "safari-ua", "safari":
                spoof = false
            default:
                break
            }
        }
        return WebExtensionPin(url: url, spoofFirefoxUA: spoof)
    }

    private static func parseBool(_ value: String) -> Bool {
        switch value.lowercased() {
        case "1", "true", "yes", "on": return true
        default: return false
        }
    }

    /// Ghostty list form: `keystroke, no-output` (omit keeps default for that flag).
    private static func applyScrollToBottom(_ value: String, to cfg: inout Config) {
        for raw in value.split(separator: ",") {
            let t = raw.trimmingCharacters(in: .whitespaces).lowercased()
            switch t {
            case "keystroke": cfg.scrollToBottomKeystroke = true
            case "no-keystroke": cfg.scrollToBottomKeystroke = false
            case "output": cfg.scrollToBottomOutput = true
            case "no-output": cfg.scrollToBottomOutput = false
            default: break
            }
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
