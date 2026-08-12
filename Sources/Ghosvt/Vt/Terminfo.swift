import Foundation

/// Bundled Ghostty terminfo (`xterm-ghostty` / `ghostty`).
enum Terminfo {
    static let termName = "xterm-ghostty"

    /// Absolute path to the terminfo database directory (contains `78/xterm-ghostty`).
    static let databasePath: String? = {
        // App Resources, SPM resource bundle (when present), then source tree.
        var candidates: [URL?] = [
            Bundle.main.url(forResource: "terminfo", withExtension: nil),
            Bundle.main.url(forResource: "terminfo", withExtension: nil, subdirectory: "Resources"),
            Bundle.main.resourceURL?.appendingPathComponent("terminfo"),
            Bundle.main.resourceURL?.appendingPathComponent("Resources/terminfo"),
        ]

        #if SWIFT_PACKAGE
        candidates.append(Bundle.module.url(forResource: "terminfo", withExtension: nil, subdirectory: "Resources"))
        candidates.append(Bundle.module.url(forResource: "terminfo", withExtension: nil))
        candidates.append(Bundle.module.resourceURL?.appendingPathComponent("Resources/terminfo"))
        candidates.append(Bundle.module.resourceURL?.appendingPathComponent("terminfo"))
        #endif

        candidates.append(
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/terminfo")
        )

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
