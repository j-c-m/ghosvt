import Foundation

/// Bundled Ghostty terminfo (`xterm-ghostty` / `ghostty`).
enum Terminfo {
    static let termName = "xterm-ghostty"

    /// Absolute path to the terminfo database directory (contains `78/xterm-ghostty`).
    static let databasePath: String? = {
        let candidates: [URL?] = [
            Bundle.module.url(forResource: "terminfo", withExtension: nil, subdirectory: "Resources"),
            Bundle.module.url(forResource: "terminfo", withExtension: nil),
            Bundle.module.resourceURL?.appendingPathComponent("Resources/terminfo"),
            Bundle.module.resourceURL?.appendingPathComponent("terminfo"),
            // Source-tree fallback (swift run from package root / debug).
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/terminfo"),
        ]
        for case let url? in candidates {
            let entry = url.appendingPathComponent("78/xterm-ghostty")
            if FileManager.default.isReadableFile(atPath: entry.path) {
                return url.path
            }
        }
        fputs("ghosvt: bundled xterm-ghostty terminfo not found\n", stderr)
        return nil
    }()

    static var isAvailable: Bool { databasePath != nil }
}
