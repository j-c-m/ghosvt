import AppKit
import Metal

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var metalView: MetalTerminalView?
    private var manager: VtManager?
    private var config = Config()
    /// True after `terminateLater` until the quit panel replies.
    private var quitTerminatePending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        config = Config.load()
        EmbeddedFonts.preload()
        // Process-global: must run before any GhosttyTerminal is created.
        KittyPngDecode.install()
        // Minimal main menu so AppKit can dispatch standard Edit actions (paste/select-all)
        // to WKWebView via the responder chain. Without this, ⌘V/⌘A do nothing in WebKit.
        installMainMenu()
        if Terminfo.databasePath == nil {
            fputs("ghosvt: warning: xterm-ghostty terminfo missing; login will use xterm-256color\n", stderr)
        }
        #if DEBUG
        if let ti = Terminfo.databasePath {
            fputs("ghosvt: TERMINFO=\(ti) TERM=\(Terminfo.termName)\n", stderr)
        }
        #endif
        manager = VtManager(config: config)

        guard let device = MTLCreateSystemDefaultDevice() else {
            fputs("ghosvt: Metal is required\n", stderr)
            NSApp.terminate(nil)
            return
        }

        let screen = NSScreen.main ?? NSScreen.screens[0]
        let frame = screen.frame

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.title = "ghosvt"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = true
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary]

        let view = MetalTerminalView(frame: frame, device: device)
        view.config = config
        view.manager = manager
        window.contentView = view
        self.metalView = view
        self.window = window

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        // Borderless-style fullscreen space
        window.toggleFullScreen(nil)

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Ensure key focus after fullscreen transition settles.
        DispatchQueue.main.async { [weak self] in
            guard let self, let view = self.metalView else { return }
            self.window?.makeFirstResponder(view)
        }

        // Local monitor runs before WebKit and menu equivalents. Swallow host
        // chords here; pass the rest so the page / Edit menu can see them.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let view = self?.metalView else { return event }
            switch view.routeKey(event) {
            case .consumed, .toPty:
                return nil
            case .toWebView, .toMenu:
                return event
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// ⌘Q / menu Quit: centered terminal panel (covers all `NSApp.terminate` paths).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitTerminatePending {
            return .terminateCancel
        }
        guard let view = metalView else {
            return .terminateNow
        }
        quitTerminatePending = true
        view.presentQuitConfirm { [weak self] confirmed in
            guard let self else { return }
            self.quitTerminatePending = false
            NSApp.reply(toApplicationShouldTerminate: confirmed)
        }
        return .terminateLater
    }

    /// App + Edit menus so standard key equivalents exist. Terminal still claims ⌘C/V via
    /// `performKeyEquivalent` when the metal view is first responder.
    @MainActor
    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Quit ghosvt", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        editItem.submenu = edit
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(NSMenuItem.separator())
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = main
    }
}
