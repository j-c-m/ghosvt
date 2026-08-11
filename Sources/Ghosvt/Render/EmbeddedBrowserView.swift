import AppKit
import WebKit

/// Chrome-less WKWebView embed. Address bar is painted by the terminal (stolen top row).
final class EmbeddedBrowserView: NSView, WKNavigationDelegate {
    var onClose: (() -> Void)?
    var onURLChange: ((String, Bool, Bool) -> Void)?
    /// Fired when the user interacts with page content (ends address-bar edit).
    var onWebContentInteraction: (() -> Void)?
    /// URL / loading / title changes for web-extension tab property notifications.
    var onNavigationStateChange: (() -> Void)?
    /// `target=_blank` / window.open — host may open a new tab; if nil, load in this view.
    var onOpenInNewTab: ((URL) -> Void)?

    private let webView: WKWebView
    private var titleObservation: NSKeyValueObservation?
    private var loadingObservation: NSKeyValueObservation?

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
        let config = WKWebViewConfiguration()
        config.preferences.isElementFullscreenEnabled = true
        if #available(macOS 15.4, *) {
            BrowserExtensionHost.shared.apply(to: config)
        }
        webView = WKWebView(frame: .zero, configuration: config)
        super.init(frame: frameRect)
        wantsLayer = true
        // Match a normal browser under-page color so unpainted HTML is white.
        layer?.backgroundColor = NSColor.white.cgColor

        webView.navigationDelegate = self
        webView.autoresizingMask = [.width, .height]
        // Draw WebKit’s own page background (white by default). Disabling this
        // left transparent areas showing the black host layer (e.g. cnbc.com).
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

    deinit {
        titleObservation?.invalidate()
        loadingObservation?.invalidate()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    func load(url: URL) {
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
    /// Returns true if the event is a page-scroll key we handle.
    @discardableResult
    func performPageScrollKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Allow bare or ⌘; leave Option/Control alone (browser shortcuts / a11y).
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

    /// Scroll roughly one viewport (browser-like page step).
    func scrollPage(up: Bool) {
        focusWebContent()
        // Prefer AppKit page-scroll actions when WebKit accepts them.
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
        // Only reassign when size actually changes — continuous frame writes can
        // upset some pages / WebKit layout (flicker, reload-looking behavior).
        if webView.frame != bounds {
            webView.frame = bounds
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        // Prefer the real web view so Edit actions and typing hit WebKit.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window?.firstResponder === self else { return }
            self.window?.makeFirstResponder(self.webView)
        }
        return super.becomeFirstResponder()
    }

    /// Only real clicks end address-bar edit — not hover/hitTest (that left the bar on mouse-over).
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

    /// Call when a left-click lands in our frame (including WKWebView internals).
    func notePageClick() {
        onWebContentInteraction?()
        focusWebContent()
    }

    private func notifyURL() {
        onURLChange?(currentURLString, canGoBack, canGoForward)
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
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        if let url = navigationAction.request.url {
            let scheme = url.scheme?.lowercased() ?? ""
            // Main document + subframes: allow normal web + opaque document schemes.
            // Cancelling blob:/data: iframes breaks many sites (and some retry forever).
            switch scheme {
            case "http", "https", "about", "blob", "data":
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
        // target=_blank / window.open
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

