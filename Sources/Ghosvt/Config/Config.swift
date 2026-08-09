import Foundation

/// User configuration from `~/.config/ghosvt/config` (Ghostty-style key = value).
struct Config: Sendable {
    var vtCount: Int = 6
    var fontSize: CGFloat = 16
    var scrollbackLines: Int = 10_000
    var scrollSpringK: Double = 120
    var scrollSpringC: Double = 14
    var scrollFriction: Double = 6

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
            case "scroll-spring-k":
                if let n = Double(value) { cfg.scrollSpringK = n }
            case "scroll-spring-c":
                if let n = Double(value) { cfg.scrollSpringC = n }
            case "scroll-friction":
                if let n = Double(value) { cfg.scrollFriction = n }
            default:
                break
            }
        }
        return cfg
    }
}
