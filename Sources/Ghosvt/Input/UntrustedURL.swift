import Foundation
import UniformTypeIdentifiers

/// URL policy for terminal-origin targets (OSC 8 / plain text under cursor).
/// Port of Ghostty macOS `UntrustedURL` — not a libghostty C API; same rules.
struct UntrustedURL: Equatable {
    enum DenialReason: Equatable {
        case malformedURL
        case unsafeCharacters
        case invalidWebURL
        case inaccessibleFile
        case unsafeFile
    }

    enum Decision: Equatable {
        case allow(URL)
        case confirm(URL)
        case deny(DenialReason)
    }

    let string: String

    init(_ string: String) {
        self.string = string
    }

    var decision: Decision {
        guard !string.isEmpty else { return .deny(.malformedURL) }
        guard !string.unicodeScalars.contains(where: Self.isUnsafeCharacter) else {
            return .deny(.unsafeCharacters)
        }
        guard
            let url = URL(string: string),
            let scheme = url.scheme?.lowercased(),
            !scheme.isEmpty
        else {
            return .deny(.malformedURL)
        }

        switch scheme {
        case "http", "https":
            guard let host = url.host, !host.isEmpty else {
                return .deny(.invalidWebURL)
            }
            return .allow(url)
        case "mailto":
            guard
                let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                !components.path.isEmpty
            else {
                return .deny(.malformedURL)
            }
            return .allow(url)
        case "file":
            return fileDecision(for: url)
        default:
            return .confirm(url)
        }
    }

    /// URL safe to load in the embedded browser (http/https allow only).
    var embeddableHTTPURL: URL? {
        switch decision {
        case .allow(let url):
            let s = url.scheme?.lowercased() ?? ""
            return (s == "http" || s == "https") ? url : nil
        default:
            return nil
        }
    }
}

private extension UntrustedURL {
    func fileDecision(for url: URL) -> Decision {
        guard url.isFileURL, url.query == nil, url.fragment == nil else {
            return .deny(.malformedURL)
        }
        if let host = url.host,
           !host.isEmpty,
           host.caseInsensitiveCompare("localhost") != .orderedSame {
            return .deny(.malformedURL)
        }
        let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
        let resourceValues: URLResourceValues
        do {
            resourceValues = try canonicalURL.resourceValues(forKeys: [
                .contentTypeKey,
                .isDirectoryKey,
                .isExecutableKey,
                .isRegularFileKey,
            ])
        } catch {
            return .deny(.inaccessibleFile)
        }
        guard resourceValues.isDirectory == true || resourceValues.isRegularFile == true else {
            return .deny(.inaccessibleFile)
        }
        guard !Self.isUnsafeFile(canonicalURL, resourceValues: resourceValues) else {
            return .deny(.unsafeFile)
        }
        return .allow(canonicalURL)
    }

    static func isUnsafeFile(_ url: URL, resourceValues: URLResourceValues) -> Bool {
        if unsafePathExtensions.contains(url.pathExtension.lowercased()) {
            return true
        }
        if let contentType = resourceValues.contentType,
           unsafeContentTypes.contains(where: { contentType.conforms(to: $0) }) {
            return true
        }
        return resourceValues.isDirectory != true && resourceValues.isExecutable == true
    }

    static func isUnsafeCharacter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F...0x9F: return true
        case 0x061C, 0x200B...0x200F, 0x202A...0x202E, 0x2066...0x2069: return true
        case 0x2028...0x2029: return true
        case 0x2060, 0xFEFF: return true
        default: return false
        }
    }

    static let unsafePathExtensions: Set<String> = [
        "action", "app", "applescript", "class", "command", "desktop",
        "inetloc", "jar", "mobileconfig", "mpkg", "pkg", "scpt",
        "terminal", "tool", "url", "webloc", "workflow",
    ]

    static let unsafeContentTypes: [UTType] = [
        .application, .executable, .script,
    ]
}
