import AppKit
import Metal
import MetalKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var metalView: MetalTerminalView?
    private var manager: VtManager?
    private var config = Config()

    func applicationDidFinishLaunching(_ notification: Notification) {
        config = Config.load()
        EmbeddedFonts.preload()
        // Process-global: must run before any GhosttyTerminal is created.
        KittyPngDecode.install()
        // Minimal main menu so AppKit can dispatch standard Edit actions (paste/select-all)
        // to WKWebView via the responder chain. Without this, ⌘V/⌘A do nothing in WebKit.
        installMainMenu()
        if let ti = Terminfo.databasePath {
            fputs("ghosvt: TERMINFO=\(ti) TERM=\(Terminfo.termName)\n", stderr)
        } else {
            fputs("ghosvt: warning: xterm-ghostty terminfo missing; login will use xterm-256color\n", stderr)
        }
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

        // Local monitor: route keys to the metal view (login + VT switch).
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let view = self.metalView, let manager = self.manager else {
                return event
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // Embedded browser owns the active VT: no PTY keys.
            if view.isBrowserActive {
                if flags.contains(.command) {
                    if event.charactersIgnoringModifiers?.lowercased() == "q" {
                        NSApp.terminate(nil)
                        return nil
                    }
                    // Host chrome: font zoom applies to terminal + browser chrome rows.
                    if view.handleFontSizeKeys(event) {
                        return nil
                    }
                    // Address bar (when editing) or app chords (Esc path is non-cmd).
                    if view.handleBrowserKeys(event) {
                        return nil
                    }
                    // Allow VT switch while browsing (browser stays on its VT).
                    if view.handleVtSwitch(event, manager: manager) {
                        return nil
                    }
                    // Page focus: drive WebKit Edit actions ourselves (monitor runs before
                    // the menu/responder path; without this ⌘V/⌘A never reach WKWebView).
                    if !view.isBrowserAddressEditing, view.handleBrowserPageEditKeys(event) {
                        return nil
                    }
                    // ⌘PgUp/PgDn → scroll page (not terminal history).
                    if !view.isBrowserAddressEditing, view.handleBrowserPageScrollKeys(event) {
                        return nil
                    }
                    return event
                }
                if view.handleBrowserKeys(event) {
                    return nil
                }
                // Address-bar edit is handled above; otherwise let WebView receive keys.
                if view.isBrowserAddressEditing {
                    return nil
                }
                // Bare PgUp/PgDn scroll the page.
                if view.handleBrowserPageScrollKeys(event) {
                    return nil
                }
                return event
            }

            // ⌘1…⌘9 / ⌘F1… / ⌘←→ → VT switch; ⌘PgUp/PgDn → scroll; ⌘F search; ⌘B browser.
            if flags.contains(.command) {
                // No main menu — handle quit ourselves.
                if event.charactersIgnoringModifiers?.lowercased() == "q" {
                    NSApp.terminate(nil)
                    return nil
                }
                // ⌘B before search so it always opens the embed on this VT.
                if view.handleOpenBrowserChord(event) {
                    return nil
                }
                if view.handleBrowserKeys(event) {
                    return nil
                }
                if view.handleFontSizeKeys(event) {
                    return nil
                }
                if view.handleSearchKeys(event) {
                    return nil
                }
                if view.handleVtSwitch(event, manager: manager) {
                    return nil
                }
                if view.handleScrollPage(event, manager: manager) {
                    return nil
                }
                // Other ⌘ chords: leave to the system/menu.
                return event
            }

            // Esc closes browser or search before PTY.
            if view.handleBrowserKeys(event) {
                return nil
            }
            if view.handleSearchKeys(event) {
                return nil
            }

            view.keyDown(with: event)
            return nil
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// ⌘Q / menu Quit: confirm before exit (covers all `NSApp.terminate` paths).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let alert = NSAlert()
        alert.messageText = "Quit ghosvt?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        return response == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
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
