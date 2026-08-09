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

            // ⌘1…⌘9 / ⌘F1… / ⌘←→ → VT switch; ⌘PgUp/PgDn → scroll (consume).
            if flags.contains(.command) {
                // No main menu — handle quit ourselves.
                if event.charactersIgnoringModifiers?.lowercased() == "q" {
                    NSApp.terminate(nil)
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

            view.keyDown(with: event)
            return nil
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
