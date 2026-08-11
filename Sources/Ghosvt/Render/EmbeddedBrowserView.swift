import AppKit
import WebKit

/// Chrome-less WKWebView embed. Address bar is painted by the terminal (stolen top row).
///
/// **Extension pages:** WebKit requires the context’s `webViewConfiguration` for
/// extension base URLs (`safari-web-extension://…`), and a normal host configuration
/// for http(s). Swaps the underlying `WKWebView` when crossing that boundary.
final class EmbeddedBrowserView: NSView, WKNavigationDelegate {
    var onClose: (() -> Void)?
    var onURLChange: ((String, Bool, Bool) -> Void)?
    /// Fired when the user interacts with page content (ends address-bar edit).
    var onWebContentInteraction: (() -> Void)?
    /// URL / loading / title changes for web-extension tab property notifications.
    var onNavigationStateChange: (() -> Void)?
    /// `target=_blank` / window.open — host may open a new tab; if nil, load in this view.
    var onOpenInNewTab: ((URL) -> Void)?

    private var webView: WKWebView
    private var titleObservation: NSKeyValueObservation?
    private var loadingObservation: NSKeyValueObservation?
    /// True when the current web view uses an extension context configuration.
    private var isExtensionPageWebView = false
    /// Avoid re-entrant swap loops while fixing a cancelled navigation.
    private var isSwappingWebView = false

    /// Underlying page view (extension tab bridge, first-responder checks).
    var pageWebView: WKWebView { webView }

    var canGoBack: Bool { webView.canGoBack }
    var canGoForward: Bool { webView.canGoForward }
    var currentURLString: String { webView.url?.absoluteString ?? "" }
    var pageTitle: String {
        let t = webView.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !t.isEmpty { return t }
        if let host = webView.url?.host, !host.isEmpty { return host }
        let s = currentURLString
        if s.isEmpty || s == "about:blank" { return "New Tab" }
        return s
    }
    /// True when the WKWebView (not the host metal view) is first responder.
    var isWebContentFirstResponder: Bool {
        window?.firstResponder === webView
            || (window?.firstResponder as? NSView)?.isDescendant(of: webView) == true
    }

    override init(frame frameRect: NSRect) {
        let config = Self.makeNormalConfiguration()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        installWebView(webView)
    }

    deinit {
        titleObservation?.invalidate()
        loadingObservation?.invalidate()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    func load(url: URL) {
        prepareWebView(for: url)
        webView.load(URLRequest(url: url))
        notifyURL()
        focusWebContent()
    }

    func goBack() {
        if webView.canGoBack { webView.goBack() }
        notifyURL()
    }

    func goForward() {
        if webView.canGoForward { webView.goForward() }
        notifyURL()
    }

    /// ⌘R reload; ⇧⌘R reloads from origin (bypass cache).
    func reload(fromOrigin: Bool = false) {
        if fromOrigin {
            webView.reloadFromOrigin()
        } else {
            webView.reload()
        }
        notifyURL()
        focusWebContent()
    }

    /// Focus the page without treating it as a “leave address bar” click.
    func focusWebContent() {
        window?.makeFirstResponder(webView)
    }

    /// Guards against WebKit / responder-chain re-entry:
    /// metal → `forwardKeyDown` → WKWebView → us → super → metal → …
    private var isDeliveringKeyDown = false

    /// Deliver a key that landed on the host view while the page should own input.
    func forwardKeyDown(_ event: NSEvent) {
        focusWebContent()
        deliverKeyDownToWebView(event)
    }

    private func deliverKeyDownToWebView(_ event: NSEvent) {
        guard !isDeliveringKeyDown else { return }
        isDeliveringKeyDown = true
        defer { isDeliveringKeyDown = false }
        webView.keyDown(with: event)
    }

    /// Standard Edit chords for the page (⌘X/C/V/A). AppKit menus alone are not enough
    /// when a local key monitor owns the terminal; we send actions to WKWebView directly.
    @discardableResult
    func performStandardEditKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command),
              !flags.contains(.control),
              !flags.contains(.option)
        else { return false }
        let ch = event.charactersIgnoringModifiers?.lowercased()
        let code = event.keyCode
        // kVK_ANSI_X/C/V/A
        let action: Selector?
        if code == 0x07 || ch == "x" { action = #selector(NSText.cut(_:)) }
        else if code == 0x08 || ch == "c" { action = #selector(NSText.copy(_:)) }
        else if code == 0x09 || ch == "v" { action = #selector(NSText.paste(_:)) }
        else if code == 0x00 || ch == "a" { action = #selector(NSText.selectAll(_:)) }
        else { action = nil }
        guard let action else { return false }
        focusWebContent()
        return NSApp.sendAction(action, to: webView, from: self)
    }

    /// Page Up / Page Down (and ⌘ variants) for document scroll.
    @discardableResult
    func performPageScrollKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.control) || flags.contains(.option) { return false }
        switch event.keyCode {
        case 116: // Page Up
            scrollPage(up: true)
            return true
        case 121: // Page Down
            scrollPage(up: false)
            return true
        default:
            return false
        }
    }

    func scrollPage(up: Bool) {
        focusWebContent()
        let sel: Selector = up
            ? #selector(NSResponder.scrollPageUp(_:))
            : #selector(NSResponder.scrollPageDown(_:))
        if NSApp.sendAction(sel, to: webView, from: self) {
            return
        }
        let dy = up ? "-window.innerHeight*0.9" : "window.innerHeight*0.9"
        webView.evaluateJavaScript(
            "window.scrollBy({top:\(dy),left:0,behavior:'auto'})",
            completionHandler: nil
        )
    }

    override func layout() {
        super.layout()
        if webView.frame != bounds {
            webView.frame = bounds
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window?.firstResponder === self else { return }
            self.window?.makeFirstResponder(self.webView)
        }
        return super.becomeFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        onWebContentInteraction?()
        focusWebContent()
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        onWebContentInteraction?()
        focusWebContent()
        super.rightMouseDown(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        onWebContentInteraction?()
        focusWebContent()
        super.otherMouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // Never `super.keyDown` — next responder is MetalTerminalView and re-enters
        // browser key routing (stack overflow on e.g. ⇧⌘← bounced from WebKit).
        if isDeliveringKeyDown { return }
        deliverKeyDownToWebView(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if performStandardEditKey(event) { return true }
        if webView.performKeyEquivalent(with: event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    func notePageClick() {
        onWebContentInteraction?()
        focusWebContent()
    }

    private func notifyURL() {
        onURLChange?(currentURLString, canGoBack, canGoForward)
        onNavigationStateChange?()
    }

    // MARK: - Configuration / swap

    /// Appended to WKWebView’s base UA so sites see a Safari-like string
    /// (`… Version/x.y.z Safari/605.1.15`) instead of bare WebKit.
    private static let safariLikeUserAgentSuffix: String = {
        let safariVersion =
            Bundle(path: "/Applications/Safari.app")?
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? {
                let v = ProcessInfo.processInfo.operatingSystemVersion
                return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
            }()
        // Match the AppleWebKit build token already present in the stock UA.
        return "Version/\(safariVersion) Safari/605.1.15"
    }()

    private static func makeNormalConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.preferences.isElementFullscreenEnabled = true
        // Stock WKWebView omits `Version/… Safari/…`; sites UA-sniff and diverge from Safari.
        config.applicationNameForUserAgent = safariLikeUserAgentSuffix
        if #available(macOS 15.4, *) {
            BrowserExtensionHost.shared.apply(to: config)
        }
        return config
    }

    private func installWebView(_ wv: WKWebView) {
        titleObservation?.invalidate()
        loadingObservation?.invalidate()
        webView.navigationDelegate = nil
        webView.removeFromSuperview()

        webView = wv
        webView.navigationDelegate = self
        webView.autoresizingMask = [.width, .height]
        webView.setValue(true, forKey: "drawsBackground")
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        addSubview(webView)
        webView.frame = bounds

        titleObservation = webView.observe(\.title, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.onNavigationStateChange?() }
        }
        loadingObservation = webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.onNavigationStateChange?() }
        }
    }

    /// Ensure the web view config matches the URL’s extension context (or normal host).
    private func prepareWebView(for url: URL) {
        guard #available(macOS 15.4, *) else { return }
        let wantsExtension = BrowserExtensionHost.shared.controller.extensionContext(for: url) != nil
        if wantsExtension == isExtensionPageWebView { return }
        swapWebView(forExtensionURL: wantsExtension ? url : nil)
    }

    /// Rebuild web view: extension URL → context config; nil → normal host config.
    private func swapWebView(forExtensionURL url: URL?) {
        guard #available(macOS 15.4, *) else { return }
        guard !isSwappingWebView else { return }
        isSwappingWebView = true
        defer { isSwappingWebView = false }

        let config: WKWebViewConfiguration
        if let url,
           let ctx = BrowserExtensionHost.shared.controller.extensionContext(for: url),
           let extConfig = ctx.webViewConfiguration {
            config = extConfig
            config.preferences.isElementFullscreenEnabled = true
            if config.applicationNameForUserAgent == nil
                || config.applicationNameForUserAgent?.isEmpty == true {
                config.applicationNameForUserAgent = Self.safariLikeUserAgentSuffix
            }
            isExtensionPageWebView = true
        } else {
            config = Self.makeNormalConfiguration()
            isExtensionPageWebView = false
        }
        let newView = WKWebView(frame: bounds, configuration: config)
        installWebView(newView)
        // Tab bridge holds weak browser; webView(for:) reads pageWebView live — no re-register needed.
        onNavigationStateChange?()
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        notifyURL()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        notifyURL()
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        notifyURL()
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        fputs(
            "ghosvt: browser provisional fail: \(error.localizedDescription)"
                + " url=\(webView.url?.absoluteString ?? "?")\n",
            stderr
        )
        notifyURL()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        if let url = navigationAction.request.url {
            let scheme = url.scheme?.lowercased() ?? ""
            // Extension pages must use the extension webViewConfiguration (WebKit cancels
            // otherwise). Swap and re-load when crossing the boundary.
            if #available(macOS 15.4, *),
               navigationAction.targetFrame?.isMainFrame != false {
                let wantsExt = BrowserExtensionHost.shared.controller.extensionContext(for: url) != nil
                if wantsExt != isExtensionPageWebView {
                    decisionHandler(.cancel)
                    swapWebView(forExtensionURL: wantsExt ? url : nil)
                    self.webView.load(URLRequest(url: url))
                    notifyURL()
                    focusWebContent()
                    return
                }
            }
            switch scheme {
            case "http", "https", "about", "blob", "data",
                 "safari-web-extension", "webkit-extension":
                // webkit-extension kept for any system-default pages.
                decisionHandler(.allow)
                return
            case "javascript":
                decisionHandler(.cancel)
                return
            default:
                break
            }
            // Only send top-level exotic schemes outside; leave subframe alone.
            if navigationAction.targetFrame?.isMainFrame != false {
                let u = UntrustedURL(url.absoluteString)
                if case .allow(let safe) = u.decision {
                    NSWorkspace.shared.open(safe)
                }
            }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let url = webView.url
        fputs(
            "ghosvt: WebContent process died\(url.map { " on \($0.absoluteString)" } ?? ""); ⌘R to reload\n",
            stderr
        )
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // target=_blank / window.open — open in a new tab when possible.
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            if let onOpenInNewTab {
                onOpenInNewTab(url)
            } else {
                load(url: url)
            }
        }
        return nil
    }
}
