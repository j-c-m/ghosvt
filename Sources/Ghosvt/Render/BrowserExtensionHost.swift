import AppKit
import CryptoKit
// Preconcurrency: WKWebExtension types are MainActor-annotated; this host is only
// used from AppKit’s main thread (not from MTKView.draw).
@preconcurrency import WebKit

/// Process-wide `WKWebExtensionController` host: tab/window bridges, lifecycle,
/// requested-only grants.
/// Main thread only. Packages are either Safari `.appex` (`appExtensionBundle`) or
/// unpacked directories with root `manifest.json` (`resourceBaseURL`).
/// Base scheme: `safari-web-extension://`.
///
/// **Load policy:** `web-extension` pins from ghosvt config, on first browser open
/// (not app launch). Safari `/Applications` autoload is off.
/// Firefox-flavored pins may spoof a desktop Firefox UA; Safari pins stay honest.
/// Install grants `requestedPermissions` and `allRequestedMatchPatterns`.
/// Optional APIs/hosts wait for a later prompt and must be declared.
/// `nativeMessaging` is never granted.
@available(macOS 15.4, *)
final class BrowserExtensionHost: NSObject, WKWebExtensionControllerDelegate {
    static let shared = BrowserExtensionHost()

    /// When true, also load Safari web-extension appexes from `/Applications`.
    private static let loadInstalledSafariExtensions = false

    /// Remote zip/xpi pin fetched into Application Support on first browser open.
    private struct RemoteDirectoryPackage {
        var url: URL
        var dirName: String
        /// Nil = infer from the unpacked manifest (gecko vs safari).
        var spoofFirefoxUA: Bool?
    }

    /// Pins from config; captured on the first load call.
    private var pendingPins: [RemoteDirectoryPackage] = []

    /// Desktop Firefox UA for packages with `spoofFirefoxUA` (Bitwarden).
    private static let firefoxExtensionUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:128.0) Gecko/20100101 Firefox/128.0"

    /// Stable controller storage partition (extension storage / site data).
    private static let configUUID = UUID(uuidString: "A7B3C9D1-4E5F-6789-ABCD-EF0123456789")!
    /// Safari package base scheme (must be registered via `MatchPattern` first).
    private static let extensionBaseScheme = "safari-web-extension"

    /// Shared extension webview config (background / popup / options).
    private let extensionWebViewConfiguration: WKWebViewConfiguration = {
        let conf = WKWebViewConfiguration()
        conf.websiteDataStore = .default()
        return conf
    }()

    private(set) lazy var controller: WKWebExtensionController = {
        WKWebExtension.MatchPattern.registerCustomURLScheme(Self.extensionBaseScheme)
        let conf = WKWebExtensionController.Configuration(identifier: Self.configUUID)
        conf.defaultWebsiteDataStore = .default()
        // Shared factory for extension pages. Firefox UA spoof is host-gated by extension id.
        Self.installFirefoxUAHook(on: extensionWebViewConfiguration.userContentController)
        conf.webViewConfiguration = extensionWebViewConfiguration
        let c = WKWebExtensionController(configuration: conf)
        c.delegate = self
        return c
    }()

    private var windowsByVT: [Int: ExtensionWindowBridge] = [:]
    /// Loaded extension contexts.
    private(set) var loadedContexts: [WKWebExtensionContext] = []
    /// Bundle IDs (or resource keys) already loaded — avoid double-load.
    private var loadedKeys: Set<String> = []
    private var extensionLoadStarted = false
    /// Context uniqueIdentifiers that should present popups with a Firefox UA.
    private var firefoxUAContextIDs: Set<String> = []
    private static var firefoxUAHookInstalled = false

    /// How the package is laid out on disk (WKWebExtension load path).
    enum PackageKind: Equatable {
        /// Safari `.appex` → `WKWebExtension(appExtensionBundle:)`.
        case safariAppex
        /// Unpacked root with `manifest.json` → `WKWebExtension(resourceBaseURL:)`.
        case directory
    }

    /// Extension package on disk (Safari appex or Firefox/Chrome-style directory).
    struct DiscoveredExtension: Equatable {
        var path: URL
        var bundleIdentifier: String
        var displayName: String
        var kind: PackageKind
        /// When true, extension pages get a desktop Firefox UA (Bitwarden, etc.).
        var spoofFirefoxUA: Bool
    }

    /// One toolbar action from a loaded extension (manifest `action`).
    struct ToolbarItem {
        let context: WKWebExtensionContext
        let action: WKWebExtension.Action
    }

    /// UI callbacks set by `MetalTerminalView` once.
    struct UIHooks {
        var activeVTIndex: () -> Int
        var focusVT: (Int) -> Void
        var dismissBrowser: (Int) -> Void
        /// Open or navigate browser on a VT (create session if needed; load in active tab).
        var openOrNavigate: (_ url: URL, _ vt: Int) -> Void
        /// Create a new tab on a VT that already has a session (or open first tab).
        var openNewTab: (_ url: URL?, _ vt: Int) -> Void
        /// Activate tab index within a VT session.
        var activateTab: (_ vt: Int, _ tabIndex: Int) -> Void
        /// Close tab; last tab dismisses the session.
        var closeTab: (_ vt: Int, _ tabIndex: Int) -> Void
        var freeVTIndex: () -> Int?
        var contentFrameInScreen: (Int) -> CGRect
        /// Whether the host app window is in fullscreen (for windowState).
        var isAppFullscreen: () -> Bool
        /// Present extension action popup (NSPopover) relative to chrome.
        var presentActionPopup: (WKWebExtension.Action, @escaping ((any Error)?) -> Void) -> Void
        /// Icon/badge/title changed — refresh address-bar action buttons.
        var onActionDidUpdate: () -> Void
    }

    var ui: UIHooks?

    /// Actions for the active tab on `vt` (or default actions if no tab).
    func toolbarItems(forVT vt: Int) -> [ToolbarItem] {
        let tab = windowsByVT[vt]?.activeTab
        return loadedContexts.compactMap { ctx in
            guard let action = ctx.action(for: tab) else { return nil }
            return ToolbarItem(context: ctx, action: action)
        }
    }

    /// User clicked a toolbar action — marks user gesture; may open popup via delegate.
    func performToolbarItem(_ item: ToolbarItem, forVT vt: Int) {
        let tab = windowsByVT[vt]?.activeTab
        item.context.performAction(for: tab)
    }

    // MARK: - Logging

    /// Soft no-op that still succeeds (extensions often ignore the error path).
    static func logUnsupported(_ op: String, detail: String = "") {
        if detail.isEmpty {
            fputs("ghosvt: webext unsupported \(op)\n", stderr)
        } else {
            fputs("ghosvt: webext unsupported \(op): \(detail)\n", stderr)
        }
    }

    /// Hard failure returned to WebKit / the extension.
    static func unsupportedError(_ message: String) -> NSError {
        logUnsupported(message)
        return NSError(
            domain: "ghosvt.webext",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    /// Complete a mutating API that we intentionally ignore (geometry, pin, etc.).
    static func completeIgnored(
        _ op: String,
        detail: String = "",
        _ completionHandler: @escaping ((any Error)?) -> Void
    ) {
        logUnsupported(op, detail: detail)
        completionHandler(nil)
    }

    // MARK: - Config

    func apply(to config: WKWebViewConfiguration) {
        config.webExtensionController = controller
    }

    // MARK: - Discover & load extensions

    /// Discover and load extension packages. Idempotent; call when the embedded
    /// browser first opens (not at app launch). Storage is ghosvt-local.
    func loadBundledExtensionsIfNeeded(pins: [Config.WebExtensionPin]) {
        guard !extensionLoadStarted else { return }
        extensionLoadStarted = true
        pendingPins = Self.remotePackages(from: pins)
        DispatchQueue.main.async { [weak self] in
            self?.startExtensionLoadPipeline()
        }
    }

    private static func remotePackages(from pins: [Config.WebExtensionPin]) -> [RemoteDirectoryPackage] {
        var taken = Set<String>()
        var out: [RemoteDirectoryPackage] = []
        out.reserveCapacity(pins.count)
        for pin in pins {
            let dir = cacheDirName(for: pin.url, taken: taken)
            taken.insert(dir)
            out.append(RemoteDirectoryPackage(
                url: pin.url,
                dirName: dir,
                spoofFirefoxUA: pin.spoofFirefoxUA
            ))
        }
        return out
    }

    private static func cacheDirName(for url: URL, taken: Set<String>) -> String {
        var stem = url.deletingPathExtension().lastPathComponent
        if stem.isEmpty { stem = "ext" }
        if !taken.contains(stem) { return stem }
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let hex = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return "\(stem)-\(hex)"
    }

    private func startExtensionLoadPipeline() {
        _ = controller // register schemes
        Task { [weak self] in
            guard let self else { return }
            var discovered: [DiscoveredExtension] = []

            if Self.loadInstalledSafariExtensions {
                let safari = Self.discoverSafariWebExtensions()
                #if DEBUG
                fputs("ghosvt: webext discovered \(safari.count) Safari appex(es)\n", stderr)
                #endif
                discovered.append(contentsOf: safari)
            }

            let pins = self.pendingPins
            for pin in pins {
                do {
                    let pkg = try await Self.ensureRemoteDirectoryPackage(pin)
                    #if DEBUG
                    fputs(
                        "ghosvt: webext package ready \(pkg.displayName) [\(pkg.bundleIdentifier)] "
                            + "firefoxUA=\(pkg.spoofFirefoxUA)\n"
                            + "  \(pkg.path.path)\n",
                        stderr
                    )
                    #endif
                    discovered.append(pkg)
                } catch {
                    fputs(
                        "ghosvt: webext package failed \(pin.dirName): \(error.localizedDescription)\n",
                        stderr
                    )
                }
            }

            for item in discovered {
                await self.loadDiscoveredExtension(item)
            }
            DispatchQueue.main.async {
                self.ui?.onActionDidUpdate()
            }
        }
    }

    /// Scan `/Applications` and `~/Applications` for Safari Web Extension appexes.
    static func discoverSafariWebExtensions() -> [DiscoveredExtension] {
        let fm = FileManager.default
        var appRoots: [URL] = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
        ]
        if let urls = fm.urls(for: .applicationDirectory, in: .localDomainMask).first {
            appRoots.append(urls)
        }
        if let urls = fm.urls(for: .applicationDirectory, in: .userDomainMask).first {
            appRoots.append(urls)
        }

        var seen = Set<String>()
        var results: [DiscoveredExtension] = []

        for root in appRoots {
            guard let apps = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for appURL in apps where appURL.pathExtension == "app" {
                let plugins = appURL
                    .appendingPathComponent("Contents", isDirectory: true)
                    .appendingPathComponent("PlugIns", isDirectory: true)
                guard let plugs = try? fm.contentsOfDirectory(
                    at: plugins,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ) else { continue }

                for plug in plugs where plug.pathExtension == "appex" {
                    guard let meta = safariWebExtensionMetadata(at: plug),
                          seen.insert(meta.bundleIdentifier).inserted
                    else { continue }
                    results.append(meta)
                }
            }
        }

        results.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        return results
    }

    private static let safariWebExtensionPoint = "com.apple.Safari.web-extension"

    private static func safariWebExtensionMetadata(at appexURL: URL) -> DiscoveredExtension? {
        guard let bundle = Bundle(url: appexURL),
              let info = bundle.infoDictionary,
              let nsExt = info["NSExtension"] as? [String: Any],
              let point = nsExt["NSExtensionPointIdentifier"] as? String,
              point == safariWebExtensionPoint
        else { return nil }

        // Prefer packages that actually ship a web extension manifest.
        let manifest = appexURL
            .appendingPathComponent("Contents/Resources/manifest.json")
        guard FileManager.default.fileExists(atPath: manifest.path) else { return nil }

        let bid = bundle.bundleIdentifier
            ?? info["CFBundleIdentifier"] as? String
            ?? appexURL.lastPathComponent
        let name = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? appexURL.deletingPathExtension().lastPathComponent
        return DiscoveredExtension(
            path: appexURL,
            bundleIdentifier: bid,
            displayName: name,
            kind: .safariAppex,
            spoofFirefoxUA: false
        )
    }

    /// Metadata for an unpacked directory package (`manifest.json` at root).
    static func directoryPackageMetadata(
        at root: URL,
        spoofFirefoxUA: Bool? = nil
    ) -> DiscoveredExtension? {
        let manifestURL = root.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let short = json["short_name"] as? String
        let rawName = json["name"] as? String
        // Prefer non-i18n placeholders when present.
        let name: String = {
            if let short, !short.hasPrefix("__MSG_") { return short }
            if let rawName, !rawName.hasPrefix("__MSG_") { return rawName }
            return short ?? rawName ?? root.lastPathComponent
        }()

        var bid = root.lastPathComponent
        var inferredFirefox = false
        if let bss = json["browser_specific_settings"] as? [String: Any] {
            if let gecko = bss["gecko"] as? [String: Any] {
                inferredFirefox = true
                if let id = gecko["id"] as? String { bid = id }
            }
            // Explicit Safari target → never spoof unless caller overrides.
            if bss["safari"] != nil, spoofFirefoxUA == nil {
                inferredFirefox = false
            }
        } else if let apps = json["applications"] as? [String: Any],
                  let gecko = apps["gecko"] as? [String: Any] {
            inferredFirefox = true
            if let id = gecko["id"] as? String { bid = id }
        }

        return DiscoveredExtension(
            path: root,
            bundleIdentifier: bid,
            displayName: name,
            kind: .directory,
            spoofFirefoxUA: spoofFirefoxUA ?? inferredFirefox
        )
    }

    // MARK: - Pinned remote packages

    private static func extensionsCacheRoot() throws -> URL {
        let fm = FileManager.default
        let base = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = base
            .appendingPathComponent("ghosvt", isDirectory: true)
            .appendingPathComponent("Extensions", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Download + unpack a zip/xpi if needed; return package meta for `resourceBaseURL` load.
    private static func ensureRemoteDirectoryPackage(
        _ pin: RemoteDirectoryPackage
    ) async throws -> DiscoveredExtension {
        let fm = FileManager.default
        let root = try extensionsCacheRoot()
            .appendingPathComponent(pin.dirName, isDirectory: true)
        let stampURL = root.appendingPathComponent(".ghosvt-source")
        let source = pin.url.absoluteString

        let stampOK: Bool = {
            guard let stamp = try? String(contentsOf: stampURL, encoding: .utf8) else { return false }
            return stamp.trimmingCharacters(in: .whitespacesAndNewlines) == source
        }()

        if directoryPackageMetadata(at: root) == nil || !stampOK {
            #if DEBUG
            fputs("ghosvt: webext fetching \(source)\n", stderr)
            #endif
            if fm.fileExists(atPath: root.path) {
                try fm.removeItem(at: root)
            }
            try fm.createDirectory(at: root, withIntermediateDirectories: true)

            let (tempZip, response) = try await URLSession.shared.download(from: pin.url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw NSError(
                    domain: "ghosvt.webext",
                    code: http.statusCode,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "HTTP \(http.statusCode) fetching \(pin.dirName)",
                    ]
                )
            }
            let archiveName = pin.url.lastPathComponent.isEmpty
                ? "\(pin.dirName).zip"
                : pin.url.lastPathComponent
            let zipURL = root.deletingLastPathComponent()
                .appendingPathComponent(archiveName)
            if fm.fileExists(atPath: zipURL.path) {
                try fm.removeItem(at: zipURL)
            }
            try fm.moveItem(at: tempZip, to: zipURL)
            try await unzip(zipURL, into: root)
            try? fm.removeItem(at: zipURL)
            try source.write(to: stampURL, atomically: true, encoding: .utf8)
        }

        // Always re-normalize so cached packages pick up new compat rules.
        try normalizeDirectoryPackageForWebKit(at: root)

        guard let meta = directoryPackageMetadata(
            at: root,
            spoofFirefoxUA: pin.spoofFirefoxUA
        ) else {
            throw NSError(
                domain: "ghosvt.webext",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "no manifest.json after unpack (\(pin.dirName))"]
            )
        }
        return meta
    }

    /// One-time hook: spoof Firefox UA only when `location.hostname` is a registered id.
    /// Safari packages stay honest; Firefox packages register their context id at load.
    private static func installFirefoxUAHook(on controller: WKUserContentController) {
        guard !firefoxUAHookInstalled else { return }
        firefoxUAHookInstalled = true
        let source = #"""
        (function () {
          var FF = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:128.0) Gecko/20100101 Firefox/128.0";
          var hosts = (self.__ghosvtFirefoxUAHosts = self.__ghosvtFirefoxUAHosts || Object.create(null));
          var original = navigator.userAgent;
          function shouldSpoof() {
            try {
              var h = String(location.hostname || "");
              return !!(hosts[h]);
            } catch (e) { return false; }
          }
          function install() {
            try {
              Object.defineProperty(Navigator.prototype, "userAgent", {
                get: function () { return shouldSpoof() ? FF : original; },
                configurable: true
              });
            } catch (e1) {
              try {
                Object.defineProperty(navigator, "userAgent", {
                  get: function () { return shouldSpoof() ? FF : original; },
                  configurable: true
                });
              } catch (e2) {}
            }
          }
          install();
        })();
        """#
        controller.addUserScript(WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        #if DEBUG
        fputs("ghosvt: webext installed Firefox UA host-gated hook\n", stderr)
        #endif
    }

    /// Register this extension id for Firefox UA spoof (must run at document-start).
    private static func registerFirefoxUAHost(
        _ contextID: String,
        on controller: WKUserContentController
    ) {
        // Escape for JS string; ids are uuid-shaped.
        let safe = contextID.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        (function () {
          var hosts = (self.__ghosvtFirefoxUAHosts = self.__ghosvtFirefoxUAHosts || Object.create(null));
          hosts["\(safe)"] = 1;
        })();
        """
        controller.addUserScript(WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
    }

    /// Light manifest fixes so directory packages load under WKWebExtension.
    private static func normalizeDirectoryPackageForWebKit(at root: URL) throws {
        let manifestURL = root.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              var json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        var changed = false

        // MV2 `browser_action` → also publish `action` for hosts that only read V3 keys.
        if json["action"] == nil, let browserAction = json["browser_action"] {
            json["action"] = browserAction
            changed = true
        }

        // Firefox-only action keys (e.g. default_area: navbar).
        if var action = json["action"] as? [String: Any],
           action.removeValue(forKey: "default_area") != nil {
            json["action"] = action
            changed = true
        }

        // Firefox-only; WebKit may reject or ignore with noise.
        if json.removeValue(forKey: "sidebar_action") != nil {
            changed = true
        }

        // Never advertise nativeMessaging (host does not grant it).
        for key in ["permissions", "optional_permissions"] {
            guard let list = json[key] as? [String] else { continue }
            let filtered = list.filter { $0 != "nativeMessaging" }
            if filtered.count != list.count {
                json[key] = filtered
                changed = true
            }
        }

        guard changed else { return }
        let out = try JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        )
        try out.write(to: manifestURL, options: .atomic)
        #if DEBUG
        fputs(
            "ghosvt: webext normalized directory manifest for WebKit (\(root.lastPathComponent))\n",
            stderr
        )
        #endif
    }

    private static func unzip(_ zipURL: URL, into dest: URL) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                proc.arguments = ["-o", "-q", zipURL.path, "-d", dest.path]
                proc.standardOutput = FileHandle.nullDevice
                proc.standardError = FileHandle.nullDevice
                do {
                    try proc.run()
                    proc.waitUntilExit()
                    if proc.terminationStatus == 0 {
                        cont.resume()
                    } else {
                        cont.resume(throwing: NSError(
                            domain: "ghosvt.webext",
                            code: Int(proc.terminationStatus),
                            userInfo: [NSLocalizedDescriptionKey: "unzip failed status=\(proc.terminationStatus)"]
                        ))
                    }
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func loadDiscoveredExtension(_ item: DiscoveredExtension) async {
        let key = item.bundleIdentifier
        if loadedKeys.contains(key) { return }

        let package: WKWebExtension
        do {
            switch item.kind {
            case .safariAppex:
                guard let bundle = Bundle(url: item.path) else {
                    fputs("ghosvt: webext cannot open appex \(item.path.path)\n", stderr)
                    return
                }
                package = try await WKWebExtension(appExtensionBundle: bundle)
            case .directory:
                try? Self.normalizeDirectoryPackageForWebKit(at: item.path)
                package = try await WKWebExtension(resourceBaseURL: item.path)
            }
        } catch {
            fputs(
                "ghosvt: webext load failed \(item.displayName) [\(item.kind)]: "
                    + "\(error.localizedDescription)\n",
                stderr
            )
            return
        }

        for err in package.errors {
            fputs(
                "ghosvt: webext package error [\(key)]: \(err.localizedDescription)\n",
                stderr
            )
        }

        #if DEBUG
        let pathNote = item.kind == .safariAppex ? "appExtensionBundle" : "resourceBaseURL"
        fputs(
            "ghosvt: webext load path=\(pathNote) kind=\(item.kind) "
                + "firefoxUA=\(item.spoofFirefoxUA) [\(key)]\n",
            stderr
        )
        #endif

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                self.finishLoading(
                    package,
                    key: key,
                    stableSeed: key,
                    spoofFirefoxUA: item.spoofFirefoxUA
                )
                cont.resume()
            }
        }
    }

    /// Register package with stable `safari-web-extension://` identity and grants.
    private func finishLoading(
        _ extensionPackage: WKWebExtension,
        key: String,
        stableSeed: String,
        spoofFirefoxUA: Bool
    ) {
        if loadedKeys.contains(key) { return }
        _ = controller

        let id = Self.stableExtensionUUID(from: stableSeed).uuidString.lowercased()
        let context = WKWebExtensionContext(for: extensionPackage)
        context.uniqueIdentifier = id
        context.baseURL = URL(string: "\(Self.extensionBaseScheme)://\(id)/")!
        context.isInspectable = true
        Self.grantRequested(on: context)

        if spoofFirefoxUA {
            firefoxUAContextIDs.insert(id)
            // Register on the shared extension UCC so background + popup both see the host.
            let ucc = extensionWebViewConfiguration.userContentController
            Self.installFirefoxUAHook(on: ucc)
            Self.registerFirefoxUAHost(id, on: ucc)
            if let conf = context.webViewConfiguration,
               conf.userContentController !== ucc {
                Self.installFirefoxUAHook(on: conf.userContentController)
                Self.registerFirefoxUAHost(id, on: conf.userContentController)
            }
            #if DEBUG
            fputs(
                "ghosvt: webext firefox UA spoof enabled for [\(key)] host=\(id)\n",
                stderr
            )
            #endif
        }

        do {
            try controller.load(context)
        } catch {
            fputs(
                "ghosvt: webext controller.load failed [\(key)]: \(error.localizedDescription)\n",
                stderr
            )
            return
        }

        loadedContexts.append(context)
        loadedKeys.insert(key)
        Self.observeContextErrors(context, key: key)

        #if DEBUG
        let name = extensionPackage.displayName ?? key
        fputs(
            "ghosvt: webext loaded \(name) v\(extensionPackage.displayVersion ?? "?") "
                + "com=\(key) id=\(id) dnr=\(context.hasContentModificationRules) "
                + "firefoxUA=\(spoofFirefoxUA)\n",
            stderr
        )
        if let action = context.action(for: nil) {
            fputs(
                "ghosvt: webext default action presentsPopup=\(action.presentsPopup) "
                    + "label=\(action.label)\n",
                stderr
            )
        } else {
            fputs("ghosvt: webext no default action for [\(key)]\n", stderr)
        }
        #endif
        for err in context.errors {
            fputs(
                "ghosvt: webext context error [\(key)]: \(err.localizedDescription)\n",
                stderr
            )
        }
        ui?.onActionDidUpdate()

        context.loadBackgroundContent { [weak self] error in
            if let error {
                fputs(
                    "ghosvt: webext background [\(key)]: \(error.localizedDescription)\n",
                    stderr
                )
            } else {
                #if DEBUG
                fputs("ghosvt: webext background ready [\(key)]\n", stderr)
                #endif
            }
            for err in context.errors {
                fputs(
                    "ghosvt: webext runtime [\(key)]: \(err.localizedDescription)\n",
                    stderr
                )
            }
            self?.ui?.onActionDidUpdate()
        }
    }

    private static func observeContextErrors(_ context: WKWebExtensionContext, key: String) {
        NotificationCenter.default.addObserver(
            forName: WKWebExtensionContext.errorsDidUpdateNotification,
            object: context,
            queue: .main
        ) { note in
            // queue: .main already; capture descriptions without crossing isolation.
            let messages: [String]
            if let ctx = note.object as? WKWebExtensionContext {
                messages = MainActor.assumeIsolated {
                    ctx.errors.map(\.localizedDescription)
                }
            } else {
                messages = []
            }
            for msg in messages {
                fputs("ghosvt: webext error update [\(key)]: \(msg)\n", stderr)
            }
        }
    }

    /// Deterministic UUID from a stable string (bundle id or fixed seed).
    private static func stableExtensionUUID(from seed: String) -> UUID {
        var hasher = SHA256()
        hasher.update(data: Data("ghosvt.webext.v1:".utf8))
        hasher.update(data: Data(seed.utf8))
        let digest = hasher.finalize()
        var bytes = Array(digest.prefix(16))
        // RFC 4122 version 4 / variant 1 bits (still deterministic).
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// Install-time grants: declared requested APIs and hosts (including content-script matches).
    /// Never grants `nativeMessaging`.
    private static func grantRequested(on context: WKWebExtensionContext) {
        let ext = context.webExtension
        var perms: [WKWebExtension.Permission: Date] = [:]
        for p in ext.requestedPermissions where p != .nativeMessaging {
            perms[p] = .distantFuture
        }
        context.grantedPermissions = perms
        for p in perms.keys {
            context.setPermissionStatus(.grantedExplicitly, for: p, expirationDate: nil)
        }
        context.setPermissionStatus(.deniedExplicitly, for: .nativeMessaging, expirationDate: nil)

        var patterns: [WKWebExtension.MatchPattern: Date] = [:]
        for p in ext.requestedPermissionMatchPatterns {
            patterns[p] = .distantFuture
        }
        for p in ext.allRequestedMatchPatterns {
            patterns[p] = .distantFuture
        }
        context.grantedPermissionMatchPatterns = patterns
        for pat in patterns.keys {
            context.setPermissionStatus(.grantedExplicitly, for: pat, expirationDate: nil)
        }

        #if DEBUG
        let permList = perms.keys.map { $0.rawValue }.sorted().joined(separator: ",")
        let hostList = patterns.keys.map(\.string).sorted().joined(separator: ",")
        fputs(
            "ghosvt: webext granted requested perms=[\(permList)] hosts=[\(hostList)]\n",
            stderr
        )
        #endif
    }

    /// Manifest-declared API permission (requested or optional). Never `nativeMessaging`.
    private static func isDeclaredPermission(
        _ permission: WKWebExtension.Permission,
        in ext: WKWebExtension
    ) -> Bool {
        guard permission != .nativeMessaging else { return false }
        return ext.requestedPermissions.contains(permission)
            || ext.optionalPermissions.contains(permission)
    }

    /// Hosts the package declared (requested, optional, or content-script matches).
    private static func declaredMatchPatterns(
        in ext: WKWebExtension
    ) -> Set<WKWebExtension.MatchPattern> {
        ext.requestedPermissionMatchPatterns
            .union(ext.optionalPermissionMatchPatterns)
            .union(ext.allRequestedMatchPatterns)
    }

    /// True when a declared pattern is at least as broad as `pattern`.
    private static func isDeclaredMatchPattern(
        _ pattern: WKWebExtension.MatchPattern,
        in ext: WKWebExtension
    ) -> Bool {
        declaredMatchPatterns(in: ext).contains { $0.matches(pattern) }
    }

    /// True when a declared pattern matches `url`.
    private static func isDeclaredURL(_ url: URL, in ext: WKWebExtension) -> Bool {
        declaredMatchPatterns(in: ext).contains { $0.matches(url) }
    }

    // MARK: - Registry / lifecycle

    @discardableResult
    func ensureWindow(vtIndex: Int) -> ExtensionWindowBridge {
        if let existing = windowsByVT[vtIndex] { return existing }
        let window = ExtensionWindowBridge(host: self, vtIndex: vtIndex)
        windowsByVT[vtIndex] = window
        controller.didOpenWindow(window)
        if ui?.activeVTIndex() == vtIndex {
            controller.didFocusWindow(window)
        }
        return window
    }

    @discardableResult
    func addTab(
        browser: EmbeddedBrowserView,
        vtIndex: Int,
        activate: Bool = true
    ) -> ExtensionTabBridge {
        let window = ensureWindow(vtIndex: vtIndex)
        let index = window.tabs.count
        let tab = ExtensionTabBridge(host: self, window: window, browser: browser, index: index)
        window.tabs.append(tab)
        controller.didOpenTab(tab)
        if activate {
            let previous = window.activeTab
            window.activeTabIndex = index
            controller.didActivateTab(tab, previousActiveTab: previous === tab ? nil : previous)
        }
        return tab
    }

    func attach(browser: EmbeddedBrowserView, vtIndex: Int, tabIndex: Int) {
        guard let window = windowsByVT[vtIndex],
              tabIndex >= 0, tabIndex < window.tabs.count
        else {
            _ = addTab(browser: browser, vtIndex: vtIndex, activate: true)
            return
        }
        window.tabs[tabIndex].browser = browser
    }

    func setActiveTab(vtIndex: Int, tabIndex: Int) {
        guard let window = windowsByVT[vtIndex],
              tabIndex >= 0, tabIndex < window.tabs.count,
              window.activeTabIndex != tabIndex
        else { return }
        let previous = window.activeTab
        window.activeTabIndex = tabIndex
        let tab = window.tabs[tabIndex]
        controller.didActivateTab(tab, previousActiveTab: previous)
    }

    func closeTab(vtIndex: Int, tabIndex: Int) {
        guard let window = windowsByVT[vtIndex],
              tabIndex >= 0, tabIndex < window.tabs.count
        else { return }
        let tab = window.tabs[tabIndex]
        let wasActive = window.activeTabIndex == tabIndex
        let closingWindow = window.tabs.count == 1
        // Notify while the tab (and its webView) are still fully attached.
        controller.didCloseTab(tab, windowIsClosing: closingWindow)
        window.tabs.remove(at: tabIndex)
        window.reindexTabs()
        if closingWindow {
            windowsByVT.removeValue(forKey: vtIndex)
            controller.didCloseWindow(window)
            if ui?.activeVTIndex() == vtIndex {
                controller.didFocusWindow(focusedWindow())
            }
            return
        }
        if window.activeTabIndex >= window.tabs.count {
            window.activeTabIndex = window.tabs.count - 1
        } else if tabIndex < window.activeTabIndex {
            window.activeTabIndex -= 1
        } else if wasActive {
            // Closed active tab: next tab slides into this index (or last).
            window.activeTabIndex = min(tabIndex, window.tabs.count - 1)
        }
        // Always notify when the closed tab was active (includes rightmost active).
        if wasActive, let active = window.activeTab {
            controller.didActivateTab(active, previousActiveTab: nil)
        }
    }

    func unregister(vtIndex: Int) {
        guard let window = windowsByVT.removeValue(forKey: vtIndex) else { return }
        for tab in window.tabs {
            controller.didCloseTab(tab, windowIsClosing: true)
        }
        controller.didCloseWindow(window)
        if ui?.activeVTIndex() == vtIndex {
            controller.didFocusWindow(focusedWindow())
        }
    }

    func focusChanged(toVT index: Int) {
        if let w = windowsByVT[index] {
            controller.didFocusWindow(w)
        } else {
            controller.didFocusWindow(nil)
        }
    }

    func tabPropertiesChanged(
        browser: EmbeddedBrowserView,
        vtIndex: Int,
        _ properties: WKWebExtension.TabChangedProperties
    ) {
        guard let window = windowsByVT[vtIndex],
              let tab = window.tabs.first(where: { $0.browser === browser })
        else { return }
        if properties.contains(.URL) || properties.contains(.loading) {
            tab.clearPendingIfSettled()
        }
        controller.didChangeTabProperties(properties, for: tab)
    }

    func window(forVT index: Int) -> ExtensionWindowBridge? {
        windowsByVT[index]
    }

    func allWindows(focusedFirst: Bool) -> [ExtensionWindowBridge] {
        var list = Array(windowsByVT.values)
        guard focusedFirst, let active = ui?.activeVTIndex(),
              let focused = windowsByVT[active]
        else { return list }
        list.removeAll { $0 === focused }
        return [focused] + list
    }

    private func focusedWindow() -> ExtensionWindowBridge? {
        guard let active = ui?.activeVTIndex() else { return nil }
        return windowsByVT[active]
    }

    // MARK: - WKWebExtensionControllerDelegate

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openWindowsFor extensionContext: WKWebExtensionContext
    ) -> [any WKWebExtensionWindow] {
        allWindows(focusedFirst: true)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        focusedWindowFor extensionContext: WKWebExtensionContext
    ) -> (any WKWebExtensionWindow)? {
        focusedWindow()
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void
    ) {
        let vt: Int
        if let w = configuration.window as? ExtensionWindowBridge {
            vt = w.vtIndex
        } else {
            vt = ui?.activeVTIndex() ?? 0
        }
        guard let ui else {
            completionHandler(nil, Self.unsupportedError("no UI host"))
            return
        }
        let before = windowsByVT[vt]?.tabs.count ?? 0
        ui.openNewTab(configuration.url, vt)
        let window = windowsByVT[vt]
        let tab = window?.tabs.last
        if let tab, (window?.tabs.count ?? 0) > before || before == 0 {
            if let parent = configuration.parentTab as? ExtensionTabBridge {
                tab.parentTabRef = parent
            }
            completionHandler(tab, nil)
        } else if let active = window?.activeTab {
            // Cap hit: navigate active tab instead of growing past max.
            if let url = configuration.url {
                active.notePendingLoad(url)
                active.browser?.load(url: url)
            }
            completionHandler(active, nil)
        } else {
            completionHandler(nil, Self.unsupportedError("failed to open tab"))
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionWindow)?, (any Error)?) -> Void
    ) {
        guard let ui else {
            completionHandler(nil, Self.unsupportedError("no UI host"))
            return
        }

        let urls = configuration.tabURLs.isEmpty
            ? [URL(string: "about:blank")!]
            : configuration.tabURLs
        let free = ui.freeVTIndex()
        let vt: Int
        let usedFreeVT: Bool
        if let free {
            vt = free
            usedFreeVT = true
            ui.openOrNavigate(urls[0], vt)
            for extra in urls.dropFirst() {
                ui.openNewTab(extra, vt)
            }
        } else {
            // No free VT: map "window" to new tab(s) on the active VT.
            vt = ui.activeVTIndex()
            usedFreeVT = false
            for url in urls {
                ui.openNewTab(url, vt)
            }
        }

        if configuration.shouldBeFocused || usedFreeVT {
            ui.focusVT(vt)
        }

        if let window = windowsByVT[vt] {
            completionHandler(window, nil)
        } else {
            completionHandler(nil, Self.unsupportedError("failed to open window"))
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openOptionsPageFor extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let url = extensionContext.optionsPageURL else {
            completionHandler(Self.unsupportedError("extension has no options page"))
            return
        }
        guard let ui else {
            completionHandler(Self.unsupportedError("no UI host"))
            return
        }
        ui.openNewTab(url, ui.activeVTIndex())
        completionHandler(nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void
    ) {
        if permissions.contains(.nativeMessaging) {
            fputs("ghosvt: webext denied nativeMessaging prompt\n", stderr)
        }
        let ext = extensionContext.webExtension
        let allowed = Set(permissions.filter { Self.isDeclaredPermission($0, in: ext) })
        let denied = permissions.subtracting(allowed)
        if !denied.isEmpty {
            let names = denied.map { $0.rawValue }.sorted().joined(separator: ",")
            fputs("ghosvt: webext denied undeclared permission prompt [\(names)]\n", stderr)
        }
        completionHandler(allowed, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionToAccess urls: Set<URL>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<URL>, Date?) -> Void
    ) {
        let ext = extensionContext.webExtension
        let allowed = Set(urls.filter { Self.isDeclaredURL($0, in: ext) })
        let denied = urls.subtracting(allowed)
        if !denied.isEmpty {
            fputs(
                "ghosvt: webext denied undeclared URL access prompt count=\(denied.count)\n",
                stderr
            )
        }
        completionHandler(allowed, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
    ) {
        let ext = extensionContext.webExtension
        let allowed = Set(matchPatterns.filter { Self.isDeclaredMatchPattern($0, in: ext) })
        let denied = matchPatterns.subtracting(allowed)
        if !denied.isEmpty {
            let names = denied.map(\.string).sorted().joined(separator: ",")
            fputs("ghosvt: webext denied undeclared match-pattern prompt [\(names)]\n", stderr)
        }
        completionHandler(allowed, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        presentActionPopup action: WKWebExtension.Action,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        if let webView = action.popupWebView {
            let wantFF = firefoxUAContextIDs.contains(context.uniqueIdentifier)
            let nextUA: String? = wantFF ? Self.firefoxExtensionUserAgent : nil
            if webView.customUserAgent != nextUA {
                webView.customUserAgent = nextUA
                // Re-run page so Bitwarden re-evaluates isSafariApi under the new UA.
                if webView.url != nil, !webView.isLoading {
                    webView.reload()
                }
            }
            #if DEBUG
            fputs(
                "ghosvt: webext popup UA spoof=\(wantFF) ctx=\(context.uniqueIdentifier)\n",
                stderr
            )
            #endif
        }
        guard let present = ui?.presentActionPopup else {
            completionHandler(Self.unsupportedError("action popup: no UI host"))
            return
        }
        present(action, completionHandler)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        didUpdate action: WKWebExtension.Action,
        forExtensionContext context: WKWebExtensionContext
    ) {
        ui?.onActionDidUpdate()
    }

    // MARK: - Native messaging (unsupported)

    func webExtensionController(
        _ controller: WKWebExtensionController,
        sendMessage message: Any,
        toApplicationWithIdentifier applicationIdentifier: String?,
        for extensionContext: WKWebExtensionContext,
        replyHandler: @escaping (Any?, (any Error)?) -> Void
    ) {
        replyHandler(nil, Self.unsupportedError("native messaging is not supported"))
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        connectUsing port: WKWebExtension.MessagePort,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        completionHandler(Self.unsupportedError("native messaging is not supported"))
    }

}

// MARK: - Window

@available(macOS 15.4, *)
final class ExtensionWindowBridge: NSObject, WKWebExtensionWindow {
    weak var host: BrowserExtensionHost?
    let vtIndex: Int
    var tabs: [ExtensionTabBridge] = []
    var activeTabIndex: Int = 0

    var activeTab: ExtensionTabBridge? {
        guard activeTabIndex >= 0, activeTabIndex < tabs.count else { return tabs.first }
        return tabs[activeTabIndex]
    }

    init(host: BrowserExtensionHost, vtIndex: Int) {
        self.host = host
        self.vtIndex = vtIndex
        super.init()
    }

    func reindexTabs() {
        for (i, t) in tabs.enumerated() { t.index = i }
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        tabs
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        activeTab
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType {
        .normal
    }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        if host?.ui?.isAppFullscreen() == true {
            return .fullscreen
        }
        return .normal
    }

    func setWindowState(
        _ state: WKWebExtension.WindowState,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        // Fullscreen single-window host: geometry/state owned by the app.
        switch state {
        case .normal, .maximized, .fullscreen:
            BrowserExtensionHost.completeIgnored(
                "setWindowState",
                detail: "\(state.rawValue) ignored (host owns window chrome)",
                completionHandler
            )
        case .minimized:
            BrowserExtensionHost.completeIgnored(
                "setWindowState",
                detail: "minimized ignored",
                completionHandler
            )
        @unknown default:
            BrowserExtensionHost.completeIgnored(
                "setWindowState",
                detail: "unknown \(state.rawValue)",
                completionHandler
            )
        }
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool {
        false
    }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        NSScreen.main?.frame ?? .null
    }

    func frame(for context: WKWebExtensionContext) -> CGRect {
        host?.ui?.contentFrameInScreen(vtIndex) ?? .null
    }

    func setFrame(
        _ frame: CGRect,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        BrowserExtensionHost.completeIgnored(
            "setFrame",
            detail: NSStringFromRect(frame),
            completionHandler
        )
    }

    func focus(
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        // focusVT → afterVtSwitch → focusChanged already fires didFocusWindow when
        // the active VT changes. Only notify here when already on this VT.
        let alreadyFocused = host?.ui?.activeVTIndex() == vtIndex
        host?.ui?.focusVT(vtIndex)
        if alreadyFocused {
            host?.controller.didFocusWindow(self)
        }
        completionHandler(nil)
    }

    func close(
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        host?.ui?.dismissBrowser(vtIndex)
        completionHandler(nil)
    }
}

// MARK: - Tab

@available(macOS 15.4, *)
final class ExtensionTabBridge: NSObject, WKWebExtensionTab {
    weak var host: BrowserExtensionHost?
    weak var windowBridge: ExtensionWindowBridge?
    weak var browser: EmbeddedBrowserView?
    weak var parentTabRef: ExtensionTabBridge?
    var index: Int
    /// URL requested via `loadURL` while navigation is in flight.
    private var pendingLoadURL: URL?

    init(
        host: BrowserExtensionHost?,
        window: ExtensionWindowBridge,
        browser: EmbeddedBrowserView,
        index: Int
    ) {
        self.host = host
        self.windowBridge = window
        self.browser = browser
        self.index = index
        super.init()
    }

    private var webView: WKWebView? { browser?.pageWebView }

    func notePendingLoad(_ url: URL) {
        pendingLoadURL = url
    }

    func clearPendingIfSettled() {
        guard let pending = pendingLoadURL else { return }
        if webView?.isLoading == false {
            pendingLoadURL = nil
            return
        }
        if webView?.url == pending {
            pendingLoadURL = nil
        }
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        windowBridge
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        index
    }

    func parentTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        parentTabRef
    }

    func setParentTab(
        _ parentTab: (any WKWebExtensionTab)?,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        parentTabRef = parentTab as? ExtensionTabBridge
        if parentTab != nil, parentTabRef == nil {
            BrowserExtensionHost.logUnsupported(
                "setParentTab",
                detail: "foreign tab type ignored"
            )
        }
        completionHandler(nil)
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? {
        webView
    }

    func title(for context: WKWebExtensionContext) -> String? {
        webView?.title
    }

    func url(for context: WKWebExtensionContext) -> URL? {
        webView?.url
    }

    func pendingURL(for context: WKWebExtensionContext) -> URL? {
        guard webView?.isLoading == true else { return nil }
        return pendingLoadURL
    }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool {
        !(webView?.isLoading ?? false)
    }

    func size(for context: WKWebExtensionContext) -> CGSize {
        webView?.bounds.size ?? .zero
    }

    func zoomFactor(for context: WKWebExtensionContext) -> Double {
        Double(webView?.pageZoom ?? 1)
    }

    func setZoomFactor(
        _ zoomFactor: Double,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let webView else {
            completionHandler(BrowserExtensionHost.unsupportedError("no webView for zoom"))
            return
        }
        webView.pageZoom = CGFloat(zoomFactor)
        host?.controller.didChangeTabProperties(.zoomFactor, for: self)
        completionHandler(nil)
    }

    func isPinned(for context: WKWebExtensionContext) -> Bool { false }

    func setPinned(
        _ pinned: Bool,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        BrowserExtensionHost.completeIgnored(
            "setPinned",
            detail: "pinned=\(pinned)",
            completionHandler
        )
    }

    func isMuted(for context: WKWebExtensionContext) -> Bool { false }

    func setMuted(
        _ muted: Bool,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        BrowserExtensionHost.completeIgnored(
            "setMuted",
            detail: "muted=\(muted)",
            completionHandler
        )
    }

    func isPlayingAudio(for context: WKWebExtensionContext) -> Bool { false }

    func isReaderModeAvailable(for context: WKWebExtensionContext) -> Bool { false }

    func isReaderModeActive(for context: WKWebExtensionContext) -> Bool { false }

    func setReaderModeActive(
        _ active: Bool,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        BrowserExtensionHost.completeIgnored(
            "setReaderModeActive",
            detail: "active=\(active)",
            completionHandler
        )
    }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        windowBridge?.activeTab === self
    }

    func setSelected(
        _ selected: Bool,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        if selected {
            activate(for: context, completionHandler: completionHandler)
        } else {
            // Single active tab model — cannot multi-select or deselect without another tab.
            BrowserExtensionHost.completeIgnored(
                "setSelected",
                detail: "deselect ignored (single active tab)",
                completionHandler
            )
        }
    }

    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool {
        true
    }

    func shouldBypassPermissions(for context: WKWebExtensionContext) -> Bool {
        false
    }

    func loadURL(
        _ url: URL,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        notePendingLoad(url)
        browser?.load(url: url)
        completionHandler(nil)
    }

    func reload(
        fromOrigin: Bool,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        browser?.reload(fromOrigin: fromOrigin)
        completionHandler(nil)
    }

    func goBack(
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        browser?.goBack()
        completionHandler(nil)
    }

    func goForward(
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        browser?.goForward()
        completionHandler(nil)
    }

    func activate(
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let vt = windowBridge?.vtIndex else {
            completionHandler(BrowserExtensionHost.unsupportedError("tab has no window"))
            return
        }
        host?.ui?.focusVT(vt)
        host?.ui?.activateTab(vt, index)
        browser?.focusWebContent()
        completionHandler(nil)
    }

    func close(
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let vt = windowBridge?.vtIndex else {
            completionHandler(BrowserExtensionHost.unsupportedError("tab has no window"))
            return
        }
        host?.ui?.closeTab(vt, index)
        completionHandler(nil)
    }

    func duplicate(
        using configuration: WKWebExtension.TabConfiguration,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void
    ) {
        guard let vt = windowBridge?.vtIndex, let host, let ui = host.ui else {
            completionHandler(nil, BrowserExtensionHost.unsupportedError("no UI host"))
            return
        }
        let url = configuration.url ?? webView?.url
        ui.openNewTab(url, vt)
        let tab = host.window(forVT: vt)?.tabs.last
        if let tab {
            tab.parentTabRef = self
            completionHandler(tab, nil)
        } else {
            completionHandler(nil, BrowserExtensionHost.unsupportedError("failed to duplicate tab"))
        }
    }

    func detectWebpageLocale(
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Locale?, (any Error)?) -> Void
    ) {
        // Prefer document language when available; fall back to system locale.
        guard let webView else {
            completionHandler(Locale.current, nil)
            return
        }
        webView.evaluateJavaScript("document.documentElement.lang || navigator.language || ''") {
            result, _ in
            DispatchQueue.main.async {
                if let s = result as? String, !s.isEmpty {
                    completionHandler(Locale(identifier: s), nil)
                } else {
                    completionHandler(Locale.current, nil)
                }
            }
        }
    }

    func takeSnapshot(
        using configuration: WKSnapshotConfiguration,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (NSImage?, (any Error)?) -> Void
    ) {
        guard let webView else {
            completionHandler(nil, BrowserExtensionHost.unsupportedError("no webView for snapshot"))
            return
        }
        webView.takeSnapshot(with: configuration) { image, error in
            DispatchQueue.main.async {
                completionHandler(image, error)
            }
        }
    }
}
