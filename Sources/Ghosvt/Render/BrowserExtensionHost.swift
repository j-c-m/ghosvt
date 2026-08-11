import AppKit
import WebKit

/// Process-wide `WKWebExtensionController` host: tab/window bridges, lifecycle events, auto-grant.
///
/// **Window model:** each VT with a browser session is one `WKWebExtensionWindow`.
/// **openNewWindow policy:** prefer a free VT (no browser); if none, open tabs on the
/// active VT. There is no second `NSWindow` — fullscreen single-window host.
@available(macOS 15.4, *)
@MainActor
final class BrowserExtensionHost: NSObject, WKWebExtensionControllerDelegate {
    static let shared = BrowserExtensionHost()
    static let maxTabsPerWindow = 8

    /// Stable id so extension storage survives relaunches.
    private static let configUUID = UUID(uuidString: "A7B3C9D1-4E5F-6789-ABCD-EF0123456789")!

    private(set) lazy var controller: WKWebExtensionController = {
        let conf = WKWebExtensionController.Configuration(identifier: Self.configUUID)
        let c = WKWebExtensionController(configuration: conf)
        c.delegate = self
        return c
    }()

    private var windowsByVT: [Int: ExtensionWindowBridge] = [:]

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
    }

    var ui: UIHooks?

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
        fputs("ghosvt: webext window open vt=\(vtIndex)\n", stderr)
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
        fputs("ghosvt: webext tab open vt=\(vtIndex) index=\(index) tabs=\(window.tabs.count)\n", stderr)
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
            fputs("ghosvt: webext window close vt=\(vtIndex)\n", stderr)
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
        fputs("ghosvt: webext tab close vt=\(vtIndex) tabs=\(window.tabs.count)\n", stderr)
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
        fputs("ghosvt: webext window close vt=\(vtIndex)\n", stderr)
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
            fputs(
                "ghosvt: webext openNewTab cap on vt=\(vt); navigating active tab\n",
                stderr
            )
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
        if configuration.shouldBePrivate {
            Self.logUnsupported(
                "openNewWindow private",
                detail: "private windows not supported; opening normal"
            )
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
            fputs(
                "ghosvt: webext openNewWindow → free vt=\(vt) tabs=\(urls.count)\n",
                stderr
            )
            ui.openOrNavigate(urls[0], vt)
            for extra in urls.dropFirst() {
                ui.openNewTab(extra, vt)
            }
        } else {
            // No free VT: map "window" to new tab(s) on the active VT.
            vt = ui.activeVTIndex()
            usedFreeVT = false
            fputs(
                "ghosvt: webext openNewWindow → no free VT; tabs on active vt=\(vt) count=\(urls.count)\n",
                stderr
            )
            for url in urls {
                ui.openNewTab(url, vt)
            }
        }

        if configuration.shouldBeFocused || usedFreeVT {
            ui.focusVT(vt)
        }
        // Frame from configuration is ignored (fullscreen host owns geometry).
        if configuration.frame != .null, configuration.frame != .zero {
            Self.logUnsupported(
                "openNewWindow frame",
                detail: "ignored \(NSStringFromRect(configuration.frame))"
            )
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
        fputs(
            "ghosvt: webext auto-grant permissions count=\(permissions.count) ext=\(extensionContext.uniqueIdentifier)\n",
            stderr
        )
        completionHandler(permissions, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionToAccess urls: Set<URL>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<URL>, Date?) -> Void
    ) {
        fputs(
            "ghosvt: webext auto-grant URL access count=\(urls.count) ext=\(extensionContext.uniqueIdentifier)\n",
            stderr
        )
        completionHandler(urls, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
    ) {
        fputs(
            "ghosvt: webext auto-grant match patterns count=\(matchPatterns.count) ext=\(extensionContext.uniqueIdentifier)\n",
            stderr
        )
        completionHandler(matchPatterns, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        presentActionPopup action: WKWebExtension.Action,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        completionHandler(Self.unsupportedError("action popup not implemented"))
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        didUpdate action: WKWebExtension.Action,
        forExtensionContext context: WKWebExtensionContext
    ) {
        // No toolbar chrome yet; log so badge/title changes are visible while debugging.
        fputs(
            "ghosvt: webext action update ext=\(context.uniqueIdentifier)\n",
            stderr
        )
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        sendMessage message: Any,
        toApplicationWithIdentifier applicationIdentifier: String?,
        for extensionContext: WKWebExtensionContext,
        replyHandler: @escaping (Any?, (any Error)?) -> Void
    ) {
        replyHandler(
            nil,
            Self.unsupportedError(
                "native messaging not implemented\(applicationIdentifier.map { " app=\($0)" } ?? "")"
            )
        )
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        connectUsing port: WKWebExtension.MessagePort,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        completionHandler(Self.unsupportedError("native messaging ports not implemented"))
    }
}

// MARK: - Window

@available(macOS 15.4, *)
@MainActor
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
@MainActor
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
        true
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
        let before = windowBridge?.tabs.count ?? 0
        ui.openNewTab(url, vt)
        let tab = host.window(forVT: vt)?.tabs.last
        if let tab {
            tab.parentTabRef = self
            if (host.window(forVT: vt)?.tabs.count ?? 0) <= before {
                fputs("ghosvt: webext duplicate hit tab cap vt=\(vt)\n", stderr)
            }
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
                if let error {
                    fputs("ghosvt: webext takeSnapshot error: \(error.localizedDescription)\n", stderr)
                    completionHandler(nil, error)
                } else {
                    completionHandler(image, nil)
                }
            }
        }
    }
}
