import AppKit
import CGhosttyVT
import Darwin
import Foundation
import Metal

/// One virtual terminal: libghostty-vt state + PTY + login child.
final class TerminalSession {
    let index: Int
    private(set) var terminal: GhosttyTerminal?
    private(set) var renderState: GhosttyRenderState?
    private(set) var rowIterator: GhosttyRenderStateRowIterator?
    private(set) var rowCells: GhosttyRenderStateRowCells?
    private(set) var keyEncoder: GhosttyKeyEncoder?
    private(set) var keyEvent: GhosttyKeyEvent?

    private(set) var masterFD: Int32 = -1
    private(set) var childPID: pid_t = -1
    private(set) var isLive: Bool = false

    /// Per-VT continuous scroll + spring overscroll (main-thread only).
    let scrollPhysics = ScrollPhysics()

    /// Kitty graphics textures + placement snapshot (main-thread; cache all VTs).
    let kittyCache = KittyGraphicsCache()

    /// Ghostty `scroll-to-bottom` flags (defaults: keystroke, no-output).
    private(set) var scrollToBottomKeystroke = true
    private(set) var scrollToBottomOutput = false
    /// Set from the parse thread when `scrollToBottomOutput`; consumed on main in `stepScroll`.
    private var pendingScrollToBottom = false
    private let scrollToBottomLock = NSLock()
    /// Consecutive ⌘PageUp/Down presses (resets on first non-repeat).
    private var pageScrollHoldCount = 0
    private var pageScrollLastDir: Double = 0

    private var cols: UInt16 = 80
    private var rows: UInt16 = 24
    private var cellWidthPx: UInt32 = 8
    private var cellHeightPx: UInt32 = 16

    private let lock = NSLock()
    private let scrollbackLimitBytes: Int
    private let consoleMode: ConsoleMode
    /// Getty banner host override; nil → system hostname.
    private let bannerHostname: String?
    /// Getty banner tty: false = ttyvN; true = PTY slave basename.
    private let bannerRealTty: Bool

    /// Last integer row pushed to `ghostty_terminal_scroll_viewport`.
    private var lastSyncedIntegerRow: UInt64?
    /// Cached scrollbar max offset (rows from top).
    private(set) var scrollMaxOffset: Double = 0
    private(set) var scrollViewportRows: Double = 24
    /// Alternate screen never keeps history (Ghostty / cmatrix / fullscreen TUIs).
    private(set) var alternateScreen = false
    /// VT bytes arrived (or the child died). Must be `@Sendable` (parse thread).
    var onNeedsRedraw: (@Sendable () -> Void)?
    /// One main hop per burst so echo does not queue a draw per gather batch.
    private final class RedrawState: @unchecked Sendable {
        let lock = NSLock()
        var scheduled = false
    }
    private let redrawState = RedrawState()

    /// Persistent bytes for GHOSTTY_TERMINAL_OPT_TERMINFO_NAME.
    private let terminfoNameBytes: [UInt8] = Array("xterm-ghostty".utf8)

    /// Context for C effects callbacks (heap-stable).
    private var effectsBox: EffectsBox?

    /// Gather + parse PTY pipeline (off main). Stop before taking `lock` for teardown.
    private var pipeline: PtyPipeline?

    // Selection gesture (main-thread; serialized with terminal lock on API calls).
    private var selectionGesture: GhosttySelectionGesture?
    private var selPressEvent: GhosttySelectionGestureEvent?
    private var selDragEvent: GhosttySelectionGestureEvent?
    private var selReleaseEvent: GhosttySelectionGestureEvent?
    private var hasSelection: Bool = false

    // Mouse encoder for TUI tracking modes.
    private var mouseEncoder: GhosttyMouseEncoder?
    private var mouseEvent: GhosttyMouseEvent?
    private var mouseButtonsDown: Set<Int> = []

    init(
        index: Int,
        scrollbackLimitBytes: Int,
        consoleMode: ConsoleMode = .login,
        bannerHostname: String? = nil,
        bannerRealTty: Bool = true
    ) {
        self.index = index
        self.scrollbackLimitBytes = scrollbackLimitBytes
        self.consoleMode = consoleMode
        self.bannerHostname = bannerHostname
        self.bannerRealTty = bannerRealTty
    }

    /// Apply config spring/friction constants to this session's physics.
    func applyScrollConfig(_ config: Config) {
        scrollPhysics.springK = config.scrollSpringK
        scrollPhysics.springC = config.scrollSpringC
        scrollPhysics.friction = config.scrollFriction
        scrollToBottomKeystroke = config.scrollToBottomKeystroke
        scrollToBottomOutput = config.scrollToBottomOutput
    }

    /// Return to the live bottom. Same smooth seek as ⌘End (Ghostty
    /// `scroll-to-bottom = keystroke`). Alternate screen stays pinned.
    func scrollViewportToBottom(isRepeat: Bool = false) {
        if alternateScreen {
            scrollPhysics.pinBottom(maxOffset: 0)
            scrollMaxOffset = 0
            return
        }
        let snap = queryScrollbar()
        let maxO = snap?.maxOffset ?? scrollMaxOffset
        scrollMaxOffset = maxO
        // Already coasting, or truly on/past the live edge: do not re-kick.
        // Pinned-but-lagging (Ctrl+C during output) still seeks to the live bottom.
        if scrollPhysics.isSeekingBottom || scrollPhysics.isAtLiveBottom(maxOffset: maxO) {
            return
        }
        scrollExtremeSmooth(direction: -1, isRepeat: isRepeat)
    }

    /// Ghostty ⌘PageUp / ⌘PageDown: smooth fling one page; accelerate while held.
    /// `direction` +1 = older (Page Up); −1 = toward bottom (Page Down).
    func scrollPageSmooth(direction: Double, isRepeat: Bool) {
        if alternateScreen { return }
        if !isRepeat || direction != pageScrollLastDir {
            pageScrollHoldCount = 1
        } else {
            pageScrollHoldCount += 1
        }
        pageScrollLastDir = direction

        let snap = queryScrollbar()
        let maxO = snap?.maxOffset ?? scrollMaxOffset
        let vp = max(1, Double(snap?.len ?? UInt64(rows)))
        scrollMaxOffset = maxO
        scrollViewportRows = vp
        scrollPhysics.applyPageImpulse(
            direction: direction,
            holdCount: pageScrollHoldCount,
            viewportRows: vp
        )
    }

    /// ⌘Home / ⌘End: same hold acceleration as page keys, longer coast to the extreme.
    func scrollExtremeSmooth(direction: Double, isRepeat: Bool) {
        if alternateScreen { return }
        if !isRepeat || direction != pageScrollLastDir {
            pageScrollHoldCount = 1
        } else {
            pageScrollHoldCount += 1
        }
        pageScrollLastDir = direction

        let snap = queryScrollbar()
        let maxO = snap?.maxOffset ?? scrollMaxOffset
        let vp = max(1, Double(snap?.len ?? UInt64(rows)))
        scrollMaxOffset = maxO
        scrollViewportRows = vp
        scrollPhysics.seekExtreme(
            direction: direction,
            holdCount: pageScrollHoldCount,
            viewportRows: vp,
            maxOffset: maxO
        )
    }

    deinit {
        tearDown()
    }

    func ensureStarted(cols: UInt16, rows: UInt16, cellWidthPx: UInt32, cellHeightPx: UInt32) {
        lock.lock()
        defer { lock.unlock() }
        if isLive { return }
        self.cols = max(1, cols)
        self.rows = max(1, rows)
        self.cellWidthPx = max(1, cellWidthPx)
        self.cellHeightPx = max(1, cellHeightPx)
        startLocked()
    }

    func resize(cols: UInt16, rows: UInt16, cellWidthPx: UInt32, cellHeightPx: UInt32) {
        lock.lock()
        defer { lock.unlock() }
        self.cols = max(1, cols)
        self.rows = max(1, rows)
        self.cellWidthPx = max(1, cellWidthPx)
        self.cellHeightPx = max(1, cellHeightPx)
        guard isLive, let terminal else { return }
        _ = ghostty_terminal_resize(terminal, self.cols, self.rows, self.cellWidthPx, self.cellHeightPx)
        if masterFD >= 0 {
            _ = ghosvt_pty_set_winsize(masterFD, self.cols, self.rows, self.cellWidthPx, self.cellHeightPx)
        }
        if let box = effectsBox {
            box.cols = self.cols
            box.rows = self.rows
            box.cellWidth = Int32(self.cellWidthPx)
            box.cellHeight = Int32(self.cellHeightPx)
        }
    }

    /// Lightweight health check: pipeline does drain+vt_write off main.
    /// Respawns only after gather has drained to EOF/EIO (`takeChildDead`).
    func pollIO() {
        guard isLive else { return }
        if pipeline?.takeChildDead() == true {
            recoverChild()
            return
        }
        // Reap zombies only — do not stop the pipeline here. Closing the master
        // before gather finishes drops the child's final output.
        lock.lock()
        if childPID > 0 {
            var status: Int32 = 0
            if waitpid(childPID, &status, WNOHANG) == childPID {
                childPID = -1
            }
        }
        lock.unlock()
    }

    /// Parse-thread entry: feed one gather batch into libghostty-vt.
    fileprivate func parsePipelineBatch(_ ptr: UnsafePointer<UInt8>, _ len: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard let terminal, len > 0 else { return }
        // Drop only after teardown cleared the terminal.
        ghostty_terminal_vt_write(terminal, ptr, len)
        if scrollToBottomOutput {
            scrollToBottomLock.lock()
            pendingScrollToBottom = true
            scrollToBottomLock.unlock()
        }
        scheduleRedraw()
    }

    /// Parse thread: coalesce to a single main-queue redraw.
    private func scheduleRedraw() {
        let state = redrawState
        state.lock.lock()
        if state.scheduled {
            state.lock.unlock()
            return
        }
        state.scheduled = true
        state.lock.unlock()
        let redraw = onNeedsRedraw
        DispatchQueue.main.async {
            state.lock.lock()
            state.scheduled = false
            state.lock.unlock()
            redraw?()
        }
    }

    /// Stop gather/parse, respawn login, start a new pipeline.
    /// Never call while holding `lock` (parse may need that lock to exit).
    private func recoverChild() {
        stopPipeline()
        lock.lock()
        respawnLocked()
        lock.unlock()
    }

    private func stopPipeline() {
        pipeline?.stop()
        pipeline = nil
    }

    /// Caller must stop any previous pipeline *outside* `lock` before this.
    private func startPipelineLocked() {
        guard masterFD >= 0, pipeline == nil else { return }
        let p = PtyPipeline(
            masterFD: masterFD,
            onParse: { [weak self] ptr, len in
                self?.parsePipelineBatch(ptr, len)
            },
            onDeath: { [weak self] in
                // `recoverReady` is set on the pipeline; main `pollIO` recovers.
                self?.scheduleRedraw()
            }
        )
        guard p.start() else {
            fputs("ghosvt: PtyPipeline start failed for ttyv\(index)\n", stderr)
            return
        }
        pipeline = p
    }

    func writeToPty(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        lock.lock()
        let fd = masterFD
        lock.unlock()
        guard fd >= 0 else { return }
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = ghosvt_pty_write_all(fd, base, raw.count)
        }
    }

    /// Encode a key-down into bytes for the PTY. Holds the session lock only
    /// for encoder access — caller must write the result without nesting locks.
    func encodeKeyDown(_ event: NSEvent) -> [UInt8]? {
        lock.lock()
        defer { lock.unlock() }
        guard let terminal, let encoder = keyEncoder, let keyEvent else { return nil }

        let mods = KeyBridge.mapMods(event.modifierFlags)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let gkey = KeyBridge.mapKey(event)
        let text = KeyBridge.encoderText(for: event)

        // --- Classic Ctrl+key → C0 byte (Ctrl-C = 0x03, Ctrl-D = 0x04, …) ---
        // Prefer this over Kitty-protocol encodings for login/shell C0 controls.
        if flags.contains(.control), !flags.contains(.command), !KeyBridge.requiresEncoder(gkey) {
            if let c0 = Self.classicControlByte(for: event) {
                return [c0]
            }
        }

        // Plain printable (no Ctrl/Cmd/Option): raw UTF-8. Never for arrows/F-keys —
        // AppKit puts those in U+F700… PUA and `encoderText` already drops them.
        if !flags.contains(.control),
           !flags.contains(.command),
           !flags.contains(.option),
           !KeyBridge.requiresEncoder(gkey),
           let text, !text.isEmpty {
            return Array(text.utf8)
        }

        ghostty_key_encoder_setopt_from_terminal(encoder, terminal)
        // Prefer Option-as-Alt (ESC prefix / meta) over dead-key glyphs for shells.
        var optionAsAlt = GHOSTTY_OPTION_AS_ALT_TRUE
        withUnsafePointer(to: &optionAsAlt) { ptr in
            ghostty_key_encoder_setopt(
                encoder,
                GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT,
                UnsafeRawPointer(ptr)
            )
        }

        let action: GhosttyKeyAction = event.isARepeat
            ? GHOSTTY_KEY_ACTION_REPEAT
            : GHOSTTY_KEY_ACTION_PRESS
        ghostty_key_event_set_key(keyEvent, gkey)
        ghostty_key_event_set_action(keyEvent, action)
        ghostty_key_event_set_mods(keyEvent, mods)
        ghostty_key_event_set_consumed_mods(keyEvent, KeyBridge.consumedMods(for: event))
        ghostty_key_event_set_unshifted_codepoint(keyEvent, KeyBridge.unshiftedCodepoint(event))
        ghostty_key_event_set_composing(keyEvent, false)

        let encoded: [UInt8] = {
            if let text, !text.isEmpty {
                return Array(text.utf8).withUnsafeBufferPointer { utf8Buf -> [UInt8] in
                    ghostty_key_event_set_utf8(keyEvent, utf8Buf.baseAddress, utf8Buf.count)
                    return Self.runKeyEncoder(encoder, keyEvent: keyEvent)
                }
            }
            ghostty_key_event_set_utf8(keyEvent, nil, 0)
            return Self.runKeyEncoder(encoder, keyEvent: keyEvent)
        }()

        // Shift/Alt+Enter → LF. Prefer this over encoder/Kitty CSI u for Grok Build.
        if Self.isShiftOrAltEnter(gkey: gkey, mods: mods) {
            return [0x0A]
        }
        if !encoded.isEmpty {
            return encoded
        }
        if let legacy = KeyBridge.legacySequence(for: gkey, mods: mods), !legacy.isEmpty {
            return legacy
        }
        if let text, !text.isEmpty {
            return Array(text.utf8)
        }
        return []
    }

    private static func isShiftOrAltEnter(gkey: GhosttyKey, mods: GhosttyMods) -> Bool {
        switch gkey {
        case GHOSTTY_KEY_ENTER, GHOSTTY_KEY_NUMPAD_ENTER:
            break
        default:
            return false
        }
        let mask = GhosttyMods(GHOSTTY_MODS_SHIFT | GHOSTTY_MODS_ALT)
        return (mods & mask) != 0
    }

    private static func runKeyEncoder(
        _ encoder: GhosttyKeyEncoder,
        keyEvent: GhosttyKeyEvent
    ) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 128)
        var written: Int = 0
        let res = out.withUnsafeMutableBufferPointer { buf -> GhosttyResult in
            ghostty_key_encoder_encode(encoder, keyEvent, buf.baseAddress, buf.count, &written)
        }
        if res == GHOSTTY_SUCCESS, written > 0 {
            return Array(out.prefix(written))
        }
        return []
    }

    /// Map Ctrl+key to a classic C0 control byte for PTY input.
    private static func classicControlByte(for event: NSEvent) -> UInt8? {
        // Prefer what AppKit already produced (usually correct for Ctrl+letter).
        if let chars = event.characters, chars.count == 1, let u = chars.unicodeScalars.first {
            let v = u.value
            if v < 0x20 { return UInt8(v) }
            if v == 0x7F { return 0x7F }
        }

        // Derive from the unshifted key when `characters` is empty or a printable letter.
        guard let raw = event.charactersIgnoringModifiers, let ch = raw.first else {
            return nil
        }

        // Ctrl+A … Ctrl+Z → 0x01 … 0x1A
        if let ascii = ch.asciiValue {
            let lower = ascii | 0x20 // force lowercase a–z
            if lower >= UInt8(ascii: "a"), lower <= UInt8(ascii: "z") {
                return lower &- UInt8(ascii: "a") &+ 1
            }
        }

        // Traditional punctuation controls
        switch ch {
        case " ", "@", "2": return 0x00 // NUL
        case "[", "3": return 0x1B      // ESC
        case "\\", "4": return 0x1C
        case "]", "5": return 0x1D
        case "^", "6": return 0x1E
        case "_", "-", "7": return 0x1F
        case "?": return 0x7F           // DEL
        default: return nil
        }
    }

    /// Snapshot terminal → render state. Hold the session lock for both begin and
    /// end so the parse thread cannot mutate the terminal mid-update (torn grapheme
    /// slices → bogus GRAPHEMES_LEN and heap corruption in cell text reads).
    func updateRenderState() {
        lock.lock()
        defer { lock.unlock() }
        guard let terminal, let renderState else { return }
        _ = ghostty_render_state_begin_update(renderState, terminal)
        _ = ghostty_render_state_end_update(renderState)
    }

    // MARK: - Scroll

    struct ScrollbarSnapshot {
        var total: UInt64
        var offset: UInt64
        var len: UInt64

        /// Max continuous scroll position (top of history = 0, bottom = this).
        var maxOffset: Double {
            total > len ? Double(total - len) : 0
        }
    }

    /// Refresh `alternateScreen` from libghostty-vt.
    private func refreshActiveScreen() {
        lock.lock()
        defer { lock.unlock() }
        refreshActiveScreenLocked()
    }

    private func refreshActiveScreenLocked() {
        guard isLive, let terminal else {
            alternateScreen = false
            return
        }
        var screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY
        let r = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen)
        alternateScreen = r == GHOSTTY_SUCCESS && screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE
    }

    /// Poll scrollbar geometry from libghostty-vt (amortized O(1)).
    func queryScrollbar() -> ScrollbarSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard isLive, let terminal else { return nil }
        var sb = GhosttyTerminalScrollbar(total: 0, offset: 0, len: 0)
        let r = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &sb)
        guard r == GHOSTTY_SUCCESS else { return nil }
        return ScrollbarSnapshot(total: sb.total, offset: sb.offset, len: sb.len)
    }

    /// True when an app has mouse tracking enabled (wheel should go to the PTY).
    func isMouseTracking() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isMouseTrackingLocked()
    }

    private func isMouseTrackingLocked() -> Bool {
        guard isLive, let terminal else { return false }
        var tracking = false
        _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &tracking)
        return tracking
    }

    /// Geometry for mouse encode (content surface in pixels, top-left origin).
    struct MouseSurface {
        var posX: Float
        var posY: Float
        var screenWidth: UInt32
        var screenHeight: UInt32
        var cellWidth: UInt32
        var cellHeight: UInt32
        var padLeft: UInt32
        var padTop: UInt32
    }

    /// Encode a mouse event into the PTY when tracking is on.
    /// Returns true if bytes were written (or encoder accepted the event).
    @discardableResult
    func encodeMouse(
        action: GhosttyMouseAction,
        button: GhosttyMouseButton?,
        surface: MouseSurface,
        mods: GhosttyMods,
        buttonNumber: Int? = nil
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isLive, let terminal, let encoder = mouseEncoder, let event = mouseEvent else {
            return false
        }
        guard isMouseTrackingLocked() else { return false }

        ghostty_mouse_encoder_setopt_from_terminal(encoder, terminal)

        var size = GhosttyMouseEncoderSize()
        size.size = MemoryLayout<GhosttyMouseEncoderSize>.size
        size.screen_width = max(1, surface.screenWidth)
        size.screen_height = max(1, surface.screenHeight)
        size.cell_width = max(1, surface.cellWidth)
        size.cell_height = max(1, surface.cellHeight)
        size.padding_left = surface.padLeft
        size.padding_top = surface.padTop
        size.padding_right = 0
        size.padding_bottom = 0
        withUnsafePointer(to: &size) { ptr in
            ghostty_mouse_encoder_setopt(encoder, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, UnsafeRawPointer(ptr))
        }

        // Track pressed buttons for drag / any-event motion.
        if let n = buttonNumber {
            switch action {
            case GHOSTTY_MOUSE_ACTION_PRESS:
                mouseButtonsDown.insert(n)
            case GHOSTTY_MOUSE_ACTION_RELEASE:
                mouseButtonsDown.remove(n)
            default:
                break
            }
        }
        var anyPressed = !mouseButtonsDown.isEmpty
        withUnsafePointer(to: &anyPressed) { ptr in
            ghostty_mouse_encoder_setopt(
                encoder,
                GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED,
                UnsafeRawPointer(ptr)
            )
        }
        var trackCell = true
        withUnsafePointer(to: &trackCell) { ptr in
            ghostty_mouse_encoder_setopt(
                encoder,
                GHOSTTY_MOUSE_ENCODER_OPT_TRACK_LAST_CELL,
                UnsafeRawPointer(ptr)
            )
        }

        ghostty_mouse_event_set_action(event, action)
        if let button {
            ghostty_mouse_event_set_button(event, button)
        } else {
            ghostty_mouse_event_clear_button(event)
        }
        ghostty_mouse_event_set_mods(event, mods)
        ghostty_mouse_event_set_position(
            event,
            GhosttyMousePosition(x: surface.posX, y: surface.posY)
        )

        var out = [UInt8](repeating: 0, count: 64)
        var written: Int = 0
        let res = out.withUnsafeMutableBufferPointer { buf -> GhosttyResult in
            ghostty_mouse_encoder_encode(
                encoder,
                event,
                buf.baseAddress.map { UnsafeMutableRawPointer($0).assumingMemoryBound(to: CChar.self) },
                buf.count,
                &written
            )
        }
        if res == GHOSTTY_SUCCESS, written > 0 {
            // writeToPty needs lock released — we're holding it. Write FD directly.
            let fd = masterFD
            if fd >= 0 {
                out.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return }
                    _ = ghosvt_pty_write_all(fd, base, written)
                }
            }
            return true
        }
        return res == GHOSTTY_SUCCESS
    }

    /// Wheel: button 4/5 (vertical) or 6/7 (horizontal) press+release pair.
    func encodeWheel(vertical: Bool, positive: Bool, surface: MouseSurface, mods: GhosttyMods) {
        let button: GhosttyMouseButton
        if vertical {
            // Positive scrollingDeltaY = content down = wheel "up" in traditional terms
            // → button 4 (scroll up). Negative → button 5.
            button = positive ? GHOSTTY_MOUSE_BUTTON_FOUR : GHOSTTY_MOUSE_BUTTON_FIVE
        } else {
            button = positive ? GHOSTTY_MOUSE_BUTTON_SIX : GHOSTTY_MOUSE_BUTTON_SEVEN
        }
        _ = encodeMouse(
            action: GHOSTTY_MOUSE_ACTION_PRESS,
            button: button,
            surface: surface,
            mods: mods,
            buttonNumber: nil
        )
        _ = encodeMouse(
            action: GHOSTTY_MOUSE_ACTION_RELEASE,
            button: button,
            surface: surface,
            mods: mods,
            buttonNumber: nil
        )
    }

    /// Focus in/out when mode 1004 is on.
    func encodeFocus(gained: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard isLive else { return }
        var cfg = GhosttyTerminalModeConfig()
        cfg.mode = ghostty_mode_new(1004, false)
        cfg.value = false
        guard let terminal,
              ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MODE, &cfg) == GHOSTTY_SUCCESS,
              cfg.value
        else { return }

        var out = [CChar](repeating: 0, count: 16)
        var written: Int = 0
        let ev: GhosttyFocusEvent = gained ? GHOSTTY_FOCUS_GAINED : GHOSTTY_FOCUS_LOST
        let res = out.withUnsafeMutableBufferPointer { buf in
            ghostty_focus_encode(ev, buf.baseAddress, buf.count, &written)
        }
        if res == GHOSTTY_SUCCESS, written > 0 {
            let fd = masterFD
            if fd >= 0 {
                let bytes = out.prefix(written).map { UInt8(bitPattern: $0) }
                bytes.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return }
                    _ = ghosvt_pty_write_all(fd, base, written)
                }
            }
        }
    }

    /// Ghostty `mouse_alternate_scroll` (DEC 1007, default on): on the
    /// alternate screen with no mouse tracking, the wheel is cursor keys.
    /// Positive `deltaRows` is older history → up. Returns true if consumed.
    func encodeAlternateScroll(deltaRows: Double) -> Bool {
        let count = Int(deltaRows.rounded(.towardZero))
        guard count != 0 else { return false }

        lock.lock()
        let seq: [UInt8]? = {
            guard isLive, let terminal else { return nil }
            var screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY
            let sr = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen)
            alternateScreen = sr == GHOSTTY_SUCCESS && screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE
            guard alternateScreen else { return nil }
            if isMouseTrackingLocked() { return nil }
            guard decModeLocked(1007, fallback: true) else { return nil }
            let app = decModeLocked(1, fallback: false)
            let up = count > 0
            if app {
                return Array((up ? "\u{1b}OA" : "\u{1b}OB").utf8)
            }
            return Array((up ? "\u{1b}[A" : "\u{1b}[B").utf8)
        }()
        lock.unlock()

        guard let seq else { return false }
        clearSelection()
        var out: [UInt8] = []
        out.reserveCapacity(seq.count * abs(count))
        for _ in 0..<abs(count) {
            out.append(contentsOf: seq)
        }
        writeToPty(out)
        return true
    }

    /// DEC private mode (`?N`). `fallback` is used when get fails (Ghostty defaults).
    private func decModeLocked(_ number: UInt16, fallback: Bool) -> Bool {
        guard let terminal else { return fallback }
        var cfg = GhosttyTerminalModeConfig()
        cfg.mode = ghostty_mode_new(number, false)
        cfg.value = fallback
        let r = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MODE, &cfg)
        return r == GHOSTTY_SUCCESS ? cfg.value : fallback
    }

    /// Wheel/trackpad impulse. Positive `deltaRows` moves toward older history (lower offset).
    func applyScrollImpulse(deltaRows: Double) {
        if alternateScreen { return }
        scrollPhysics.applyImpulse(deltaRows: deltaRows)
    }

    /// Fractional pixel shift in row units for the renderer.
    func visualOffsetRows() -> Double {
        if alternateScreen { return 0 }
        return scrollPhysics.visualOffsetRows(maxOffset: scrollMaxOffset)
    }

    /// Integrate physics, pin-follow, and push integer viewport to ghostty.
    /// Returns true while the spring/coast still needs frames.
    @discardableResult
    func stepScroll(dt: Double) -> Bool {
        guard isLive else { return false }

        refreshActiveScreen()
        if alternateScreen {
            // Same as Ghostty: no history, no spring, no viewport seek.
            if !scrollPhysics.pinnedToBottom || scrollMaxOffset != 0 || scrollPhysics.position != 0 {
                scrollPhysics.pinBottom(maxOffset: 0)
            }
            scrollMaxOffset = 0
            return false
        }

        let snap = queryScrollbar()
        let maxO = snap?.maxOffset ?? 0
        let vpRows = Double(snap?.len ?? UInt64(rows))
        scrollMaxOffset = maxO
        scrollViewportRows = max(1, vpRows)

        // Ghostty `scroll-to-bottom = output`: force bottom when new PTY data arrived.
        scrollToBottomLock.lock()
        let forceBottom = pendingScrollToBottom
        if forceBottom { pendingScrollToBottom = false }
        scrollToBottomLock.unlock()
        if forceBottom {
            scrollPhysics.pinBottom(maxOffset: maxO)
        }

        // New output grows history: stay glued when pinned.
        scrollPhysics.followBottomIfPinned(maxOffset: maxO)

        // Clamp only after a trim (idle past the new bottom). Do not kill
        // overscroll bounce while velocity is still carrying past maxO.
        if !scrollPhysics.pinnedToBottom,
           scrollPhysics.position > maxO,
           abs(scrollPhysics.velocity) < 0.15 {
            scrollPhysics.syncFromScrollbar(offset: maxO, maxOffset: maxO, forcePinIfActive: false)
        }

        let animating = scrollPhysics.step(dt: dt, maxOffset: maxO, viewportRows: scrollViewportRows)
        syncIntegerViewport()
        return animating
            || abs(scrollPhysics.velocity) > 0.01
            || scrollPhysics.position < -0.01
            || scrollPhysics.position > maxO + 0.01
    }

    /// Push floor(position) into ghostty when it changes.
    private func syncIntegerViewport() {
        lock.lock()
        defer { lock.unlock() }
        guard isLive, let terminal else { return }

        if scrollPhysics.pinnedToBottom {
            if lastSyncedIntegerRow != UInt64.max {
                var sv = GhosttyTerminalScrollViewport()
                sv.tag = GHOSTTY_SCROLL_VIEWPORT_BOTTOM
                ghostty_terminal_scroll_viewport(terminal, sv)
                lastSyncedIntegerRow = UInt64.max
            }
            return
        }

        let row = scrollPhysics.integerRow(maxOffset: scrollMaxOffset)
        if lastSyncedIntegerRow == row { return }
        var sv = GhosttyTerminalScrollViewport()
        sv.tag = GHOSTTY_SCROLL_VIEWPORT_ROW
        sv.value.row = Int(row)
        ghostty_terminal_scroll_viewport(terminal, sv)
        lastSyncedIntegerRow = row
    }

    // MARK: - Private

    private func startLocked() {
        var term: GhosttyTerminal?
        let r = ghostty_terminal_new(nil, &term, cols, rows)
        guard r == GHOSTTY_SUCCESS, let term else {
            fputs("ghosvt: ghostty_terminal_new failed (\(r.rawValue))\n", stderr)
            return
        }
        terminal = term

        // Ghostty-style scrollback-limit (bytes). NULL would mean unlimited;
        // zero disables scrollback. Do not set max-lines — bytes alone bind.
        if scrollbackLimitBytes == Int.max {
            _ = ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, nil)
        } else {
            var bytes = scrollbackLimitBytes
            withUnsafePointer(to: &bytes) { ptr in
                _ = ghostty_terminal_set(
                    term,
                    GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES,
                    UnsafeRawPointer(ptr)
                )
            }
        }
        DefaultColors.apply(to: term)

        // Advertise as xterm-ghostty (matches bundled terminfo / Ghostty capabilities).
        terminfoNameBytes.withUnsafeBufferPointer { buf in
            var gs = GhosttyString(ptr: buf.baseAddress, len: buf.count)
            _ = ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_TERMINFO_NAME, &gs)
        }

        // Enable Kitty graphics protocol storage (Ghostty feature set).
        var kittyLimit: UInt64 = 64 * 1024 * 1024
        withUnsafePointer(to: &kittyLimit) { ptr in
            _ = ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, UnsafeRawPointer(ptr))
        }
        var mediumOn = true
        withUnsafePointer(to: &mediumOn) { ptr in
            _ = ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_FILE, UnsafeRawPointer(ptr))
            _ = ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_SHARED_MEM, UnsafeRawPointer(ptr))
        }

        _ = ghostty_terminal_resize(term, cols, rows, cellWidthPx, cellHeightPx)

        var rs: GhosttyRenderState?
        if ghostty_render_state_new(nil, &rs) == GHOSTTY_SUCCESS {
            renderState = rs
        }
        var it: GhosttyRenderStateRowIterator?
        if ghostty_render_state_row_iterator_new(nil, &it) == GHOSTTY_SUCCESS {
            rowIterator = it
        }
        var cells: GhosttyRenderStateRowCells?
        if ghostty_render_state_row_cells_new(nil, &cells) == GHOSTTY_SUCCESS {
            rowCells = cells
        }
        var enc: GhosttyKeyEncoder?
        if ghostty_key_encoder_new(nil, &enc) == GHOSTTY_SUCCESS {
            keyEncoder = enc
        }
        var ev: GhosttyKeyEvent?
        if ghostty_key_event_new(nil, &ev) == GHOSTTY_SUCCESS {
            keyEvent = ev
        }
        var menc: GhosttyMouseEncoder?
        if ghostty_mouse_encoder_new(nil, &menc) == GHOSTTY_SUCCESS {
            mouseEncoder = menc
        }
        var mev: GhosttyMouseEvent?
        if ghostty_mouse_event_new(nil, &mev) == GHOSTTY_SUCCESS {
            mouseEvent = mev
        }

        installEffectsLocked()
        spawnLoginLocked()
        // Live before pipeline starts so early banner bytes are not dropped.
        isLive = true
        startPipelineLocked()
    }

    private func spawnLoginLocked() {
        var pid: pid_t = -1
        let mode: GhosvtConsoleMode = consoleMode == .shell
            ? GHOSVT_CONSOLE_SHELL
            : GHOSVT_CONSOLE_LOGIN
        let hostOverride = bannerHostname.flatMap { $0.isEmpty ? nil : $0 }
        let terminfo = Terminfo.databasePath

        func spawn(
            terminfoPath: UnsafePointer<CChar>?,
            hostname: UnsafePointer<CChar>?
        ) -> Int32 {
            ghosvt_pty_spawn(
                Int32(index),
                cols,
                rows,
                cellWidthPx,
                cellHeightPx,
                terminfoPath,
                mode,
                hostname,
                bannerRealTty ? 1 : 0,
                &pid
            )
        }

        let fd: Int32
        switch (terminfo, hostOverride) {
        case let (path?, host?):
            fd = path.withCString { cPath in
                host.withCString { cHost in
                    spawn(terminfoPath: cPath, hostname: cHost)
                }
            }
        case let (path?, nil):
            fd = path.withCString { spawn(terminfoPath: $0, hostname: nil) }
        case let (nil, host?):
            fd = host.withCString { spawn(terminfoPath: nil, hostname: $0) }
        case (nil, nil):
            fd = spawn(terminfoPath: nil, hostname: nil)
        }
        if fd < 0 {
            let err = String(cString: strerror(errno))
            fputs("ghosvt: forkpty/spawn failed for ttyv\(index): \(err)\n", stderr)
            masterFD = -1
            childPID = -1
            return
        }
        masterFD = fd
        childPID = pid
        effectsBox?.ptyFD = fd
    }

    /// Assumes pipeline is already stopped (no concurrent parse on this terminal).
    private func respawnLocked() {
        if masterFD >= 0 {
            close(masterFD)
            masterFD = -1
        }
        if childPID > 0 {
            var status: Int32 = 0
            _ = waitpid(childPID, &status, WNOHANG)
            childPID = -1
        }
        if let terminal {
            ghostty_terminal_reset(terminal)
            // Reset clears colors; reinstall host theme (fg/bg/cursor + ANSI).
            DefaultColors.apply(to: terminal)
        }
        lastSyncedIntegerRow = nil
        scrollMaxOffset = 0
        alternateScreen = false
        scrollPhysics.pinBottom(maxOffset: 0)
        spawnLoginLocked()
        startPipelineLocked()
    }

    private func installEffectsLocked() {
        guard let terminal else { return }
        let box = EffectsBox(
            ptyFD: masterFD,
            cellWidth: Int32(cellWidthPx),
            cellHeight: Int32(cellHeightPx),
            cols: cols,
            rows: rows
        )
        effectsBox = box
        let raw = Unmanaged.passUnretained(box).toOpaque()
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_USERDATA, raw)

        setFn(terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY, effectWritePty as GhosttyTerminalWritePtyFn)
        setFn(terminal, GHOSTTY_TERMINAL_OPT_SIZE, effectSize as GhosttyTerminalSizeFn)
        setFn(terminal, GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES, effectDeviceAttributes as GhosttyTerminalDeviceAttributesFn)
        setFn(terminal, GHOSTTY_TERMINAL_OPT_XTVERSION, effectXtversion as GhosttyTerminalXtversionFn)
        setFn(terminal, GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE, effectClipboardWrite as GhosttyTerminalClipboardWriteFn)
    }

    private func setFn<T>(_ terminal: GhosttyTerminal, _ opt: GhosttyTerminalOption, _ fn: T) {
        let ptr = unsafeBitCast(fn, to: UnsafeRawPointer.self)
        _ = ghostty_terminal_set(terminal, opt, ptr)
    }

    private func tearDown() {
        // Join IO threads first — parse may need `lock` to finish a batch.
        stopPipeline()
        lock.lock()
        defer { lock.unlock() }
        isLive = false
        if masterFD >= 0 {
            close(masterFD)
            masterFD = -1
        }
        if childPID > 0 {
            kill(childPID, SIGTERM)
            var status: Int32 = 0
            _ = waitpid(childPID, &status, 0)
            childPID = -1
        }
        freeSelectionGestureLocked()
        if let mouseEvent { ghostty_mouse_event_free(mouseEvent) }
        if let mouseEncoder { ghostty_mouse_encoder_free(mouseEncoder) }
        if let keyEvent { ghostty_key_event_free(keyEvent) }
        if let keyEncoder { ghostty_key_encoder_free(keyEncoder) }
        if let rowCells { ghostty_render_state_row_cells_free(rowCells) }
        if let rowIterator { ghostty_render_state_row_iterator_free(rowIterator) }
        if let renderState { ghostty_render_state_free(renderState) }
        if let terminal { ghostty_terminal_free(terminal) }
        self.mouseEvent = nil
        self.mouseEncoder = nil
        self.keyEvent = nil
        self.keyEncoder = nil
        self.rowCells = nil
        self.rowIterator = nil
        self.renderState = nil
        self.terminal = nil
        mouseButtonsDown.removeAll()
    }

    // MARK: - Selection / clipboard

    private func ensureSelectionGestureLocked() {
        guard selectionGesture == nil else { return }
        var g: GhosttySelectionGesture?
        if ghostty_selection_gesture_new(nil, &g) == GHOSTTY_SUCCESS {
            selectionGesture = g
        }
        var press: GhosttySelectionGestureEvent?
        if ghostty_selection_gesture_event_new(nil, &press, GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_PRESS) == GHOSTTY_SUCCESS {
            selPressEvent = press
        }
        var drag: GhosttySelectionGestureEvent?
        if ghostty_selection_gesture_event_new(nil, &drag, GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_DRAG) == GHOSTTY_SUCCESS {
            selDragEvent = drag
        }
        var release: GhosttySelectionGestureEvent?
        if ghostty_selection_gesture_event_new(nil, &release, GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_RELEASE) == GHOSTTY_SUCCESS {
            selReleaseEvent = release
        }
    }

    private func freeSelectionGestureLocked() {
        if let g = selectionGesture {
            ghostty_selection_gesture_free(g, terminal)
        }
        if let e = selPressEvent { ghostty_selection_gesture_event_free(e) }
        if let e = selDragEvent { ghostty_selection_gesture_event_free(e) }
        if let e = selReleaseEvent { ghostty_selection_gesture_event_free(e) }
        selectionGesture = nil
        selPressEvent = nil
        selDragEvent = nil
        selReleaseEvent = nil
        hasSelection = false
    }

    /// Geometry + pointer mapping for selection (surface pixels, top-left of content).
    struct SelectionHit {
        var col: UInt16
        var row: UInt16
        var surfaceX: Double
        var surfaceY: Double
        var geometry: GhosttySelectionGestureGeometry
    }

    /// Map a view point (AppKit bottom-left points) into a viewport cell hit.
    func selectionHit(
        viewPoint: CGPoint,
        viewSize: CGSize,
        contentRectPoints: CGRect,
        cellWidthPoints: CGFloat,
        cellHeightPoints: CGFloat,
        padPoints: CGFloat,
        scale: CGFloat
    ) -> SelectionHit? {
        guard cellWidthPoints > 0, cellHeightPoints > 0, scale > 0 else { return nil }
        // ContentLayout y is top-origin; convert AppKit y → top-origin.
        let yFromTop = viewSize.height - viewPoint.y
        let localX = viewPoint.x - contentRectPoints.minX - padPoints
        let localY = yFromTop - contentRectPoints.minY - padPoints
        guard localX >= 0, localY >= 0 else { return nil }

        let col = Int(localX / cellWidthPoints)
        let row = Int(localY / cellHeightPoints)
        let c = Int(cols)
        let r = Int(rows)
        guard col >= 0, row >= 0, col < c, row < r else { return nil }

        let surfX = Double((viewPoint.x - contentRectPoints.minX) * scale)
        let surfY = Double((yFromTop - contentRectPoints.minY) * scale)
        var geo = GhosttySelectionGestureGeometry()
        geo.columns = UInt32(cols)
        geo.cell_width = UInt32(max(1, (cellWidthPoints * scale).rounded()))
        geo.padding_left = UInt32(max(0, (padPoints * scale).rounded()))
        geo.screen_height = UInt32(max(1, (contentRectPoints.height * scale).rounded()))
        return SelectionHit(
            col: UInt16(col),
            row: UInt16(row),
            surfaceX: surfX,
            surfaceY: surfY,
            geometry: geo
        )
    }

    private func viewportRefLocked(col: UInt16, row: UInt16) -> GhosttyGridRef? {
        guard let terminal else { return nil }
        var ref = GhosttyGridRef()
        ref.size = MemoryLayout<GhosttyGridRef>.size
        var point = GhosttyPoint()
        point.tag = GHOSTTY_POINT_TAG_VIEWPORT
        point.value.coordinate.x = col
        point.value.coordinate.y = UInt32(row)
        let r = ghostty_terminal_grid_ref(terminal, point, &ref)
        guard r == GHOSTTY_SUCCESS else { return nil }
        return ref
    }

    private func installSelectionLocked(_ selection: UnsafePointer<GhosttySelection>?) {
        guard let terminal else { return }
        if let selection {
            _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, UnsafeRawPointer(selection))
            hasSelection = true
        } else {
            _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, nil)
            hasSelection = false
        }
        // Force a full grid rebuild so invert highlight updates while dragging.
        if let renderState {
            var dirty = GHOSTTY_RENDER_STATE_DIRTY_FULL
            _ = ghostty_render_state_set(renderState, GHOSTTY_RENDER_STATE_OPTION_DIRTY, &dirty)
        }
    }

    /// Begin selection press (single/double/triple via time_ns). Returns true if handled.
    @discardableResult
    func selectionPress(hit: SelectionHit, timeNs: UInt64, rectangle: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isLive, let terminal else { return false }
        ensureSelectionGestureLocked()
        guard let gesture = selectionGesture, let press = selPressEvent else { return false }
        guard var ref = viewportRefLocked(col: hit.col, row: hit.row) else { return false }

        _ = ghostty_selection_gesture_event_set(press, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref)
        var pos = GhosttySurfacePosition(x: hit.surfaceX, y: hit.surfaceY)
        _ = ghostty_selection_gesture_event_set(press, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &pos)
        var t = timeNs
        _ = ghostty_selection_gesture_event_set(press, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_TIME_NS, &t)
        var dist: Double = 4
        _ = ghostty_selection_gesture_event_set(press, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_DISTANCE, &dist)
        var interval: UInt64 = 500_000_000
        _ = ghostty_selection_gesture_event_set(press, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_INTERVAL_NS, &interval)
        // rectangle flag is applied on drag; clear selection on new press if single-click path
        _ = rectangle

        var out = GhosttySelection()
        out.size = MemoryLayout<GhosttySelection>.size
        let res = ghostty_selection_gesture_event(gesture, terminal, press, &out)
        if res == GHOSTTY_SUCCESS {
            installSelectionLocked(&out)
        } else {
            // Single press often returns NO_VALUE (anchor only) — clear old selection.
            installSelectionLocked(nil)
        }
        return true
    }

    /// Drag update. `rectangle` true for Option+drag block select.
    @discardableResult
    func selectionDrag(hit: SelectionHit, rectangle: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isLive, let terminal else { return false }
        ensureSelectionGestureLocked()
        guard let gesture = selectionGesture, let drag = selDragEvent else { return false }
        guard var ref = viewportRefLocked(col: hit.col, row: hit.row) else { return false }

        _ = ghostty_selection_gesture_event_set(drag, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref)
        var pos = GhosttySurfacePosition(x: hit.surfaceX, y: hit.surfaceY)
        _ = ghostty_selection_gesture_event_set(drag, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &pos)
        var geo = hit.geometry
        _ = ghostty_selection_gesture_event_set(drag, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_GEOMETRY, &geo)
        var rect = rectangle
        _ = ghostty_selection_gesture_event_set(drag, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_RECTANGLE, &rect)

        var out = GhosttySelection()
        out.size = MemoryLayout<GhosttySelection>.size
        let res = ghostty_selection_gesture_event(gesture, terminal, drag, &out)
        if res == GHOSTTY_SUCCESS {
            installSelectionLocked(&out)
            return true
        }
        return false
    }

    func selectionRelease(hit: SelectionHit?) {
        lock.lock()
        defer { lock.unlock() }
        guard isLive, let terminal else { return }
        ensureSelectionGestureLocked()
        guard let gesture = selectionGesture, let release = selReleaseEvent else { return }
        if let hit, var ref = viewportRefLocked(col: hit.col, row: hit.row) {
            _ = ghostty_selection_gesture_event_set(release, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref)
        } else {
            _ = ghostty_selection_gesture_event_set(release, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, nil)
        }
        _ = ghostty_selection_gesture_event(gesture, terminal, release, nil)
    }

    func clearSelection() {
        lock.lock()
        defer { lock.unlock() }
        installSelectionLocked(nil)
        if let gesture = selectionGesture, let terminal {
            ghostty_selection_gesture_reset(gesture, terminal)
        }
    }

    var selectionActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasSelection
    }

    /// Plain-text of the active selection (unwrap + trim, Ghostty copy semantics).
    func selectionPlainText() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard isLive, let terminal, hasSelection else { return nil }
        var opts = GhosttyTerminalSelectionFormatOptions()
        opts.size = MemoryLayout<GhosttyTerminalSelectionFormatOptions>.size
        opts.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
        opts.unwrap = true
        opts.trim = true
        opts.selection = nil
        var ptr: UnsafeMutablePointer<UInt8>?
        var len: Int = 0
        let r = ghostty_terminal_selection_format_alloc(terminal, nil, opts, &ptr, &len)
        guard r == GHOSTTY_SUCCESS, let ptr, len > 0 else { return nil }
        defer { ghostty_free(nil, ptr, len) }
        return String(bytes: UnsafeBufferPointer(start: ptr, count: len), encoding: .utf8)
    }

    /// Ghostty `select_all`. Returns false when there is no selectable content.
    @discardableResult
    func selectAll() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isLive, let terminal else { return false }
        var sel = GhosttySelection()
        sel.size = MemoryLayout<GhosttySelection>.size
        let r = ghostty_terminal_select_all(terminal, &sel)
        guard r == GHOSTTY_SUCCESS else { return false }
        installSelectionLocked(&sel)
        return true
    }

    /// Ghostty `clear_screen`. False on the alternate screen (do not consume the key).
    @discardableResult
    func clearScreen() -> Bool {
        lock.lock()
        refreshActiveScreenLocked()
        guard !alternateScreen, isLive, let terminal else {
            lock.unlock()
            return false
        }
        installSelectionLocked(nil)
        if let gesture = selectionGesture {
            ghostty_selection_gesture_reset(gesture, terminal)
        }
        // CSI 3J (scrollback) + CSI 2J CSI H (active display). Ghostty
        // gates the display wipe + PTY FF on cursor-at-prompt; the pin
        // has no CURSOR_AT_PROMPT yet, so always wipe and send FF.
        let erase: [UInt8] = [
            0x1B, 0x5B, 0x33, 0x4A,
            0x1B, 0x5B, 0x32, 0x4A,
            0x1B, 0x5B, 0x48,
        ]
        ghostty_terminal_vt_write(terminal, erase, erase.count)
        lock.unlock()
        writeToPty([0x0C])
        scrollViewportToBottom()
        scheduleRedraw()
        return true
    }

    @discardableResult
    func copySelectionToPasteboard() -> Bool {
        guard let text = selectionPlainText(), !text.isEmpty else { return false }
        Clipboard.copyString(text)
        return true
    }

    /// Paste UTF-8 text into the PTY (bracketed when mode 2004 is on).
    func pasteText(_ text: String) {
        guard !text.isEmpty else { return }
        lock.lock()
        let bracketed: Bool = {
            guard let terminal else { return false }
            var cfg = GhosttyTerminalModeConfig()
            cfg.mode = ghostty_mode_new(2004, false) // bracketed paste
            cfg.value = false
            let r = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MODE, &cfg)
            return r == GHOSTTY_SUCCESS && cfg.value
        }()
        lock.unlock()

        var chars = Array(text.utf8).map { CChar(bitPattern: $0) }
        guard !chars.isEmpty else { return }
        // ghostty_paste_encode mutates input and may expand for bracketed wrap.
        var outCap = chars.count + 64
        var out = [CChar](repeating: 0, count: outCap)
        var written: Int = 0
        while true {
            let res = chars.withUnsafeMutableBufferPointer { inBuf -> GhosttyResult in
                out.withUnsafeMutableBufferPointer { outBuf in
                    ghostty_paste_encode(
                        inBuf.baseAddress,
                        inBuf.count,
                        bracketed,
                        outBuf.baseAddress,
                        outBuf.count,
                        &written
                    )
                }
            }
            if res == GHOSTTY_SUCCESS, written > 0 {
                let bytes = out.prefix(written).map { UInt8(bitPattern: $0) }
                writeToPty(Array(bytes))
                return
            }
            if res == GHOSTTY_OUT_OF_SPACE, written > outCap {
                outCap = written
                out = [CChar](repeating: 0, count: outCap)
                chars = Array(text.utf8).map { CChar(bitPattern: $0) }
                continue
            }
            // Fallback: raw CR-normalized paste.
            let raw = text.replacingOccurrences(of: "\n", with: "\r")
            writeToPty(Array(raw.utf8))
            return
        }
    }

    // MARK: - Scrollback search

    /// One match in screen coordinates (POINT_TAG_SCREEN). End column inclusive.
    struct SearchMatch: Equatable {
        var screenY: UInt32
        var startX: UInt16
        var endX: UInt16
    }

    /// Find all matches of `needle` in the full screen (history + active).
    ///
    /// Uses Ghostty `ScreenSearch` via the temporary C shim
    /// (`ghostty_screen_search_*`) until official 1.4.0 C bindings ship.
    /// Holds the session lock for the full search (same rule as selection).
    /// Results are newest-first (bottom toward history).
    func findMatches(needle: String) -> [SearchMatch] {
        let trimmed = needle
        guard !trimmed.isEmpty else { return [] }
        lock.lock()
        defer { lock.unlock() }
        guard isLive, let terminal else { return [] }

        var handle: GhosttyScreenSearch?
        let r: GhosttyResult = trimmed.withCString { cstr in
            let len = trimmed.utf8.count
            return ghostty_screen_search_new(
                nil,
                terminal,
                UnsafeRawPointer(cstr).assumingMemoryBound(to: UInt8.self),
                len,
                &handle
            )
        }
        guard r == GHOSTTY_SUCCESS, let handle else { return [] }
        defer { ghostty_screen_search_free(handle) }

        var count: Int = 0
        guard ghostty_screen_search_match_count(handle, &count) == GHOSTTY_SUCCESS,
              count > 0
        else { return [] }

        var matches: [SearchMatch] = []
        matches.reserveCapacity(count)
        for i in 0..<count {
            var m = GhosttyScreenSearchMatch()
            m.size = MemoryLayout<GhosttyScreenSearchMatch>.size
            guard ghostty_screen_search_match_at(handle, i, &m) == GHOSTTY_SUCCESS else {
                continue
            }
            matches.append(SearchMatch(
                screenY: m.y,
                startX: m.start_x,
                endX: m.end_x
            ))
        }
        return matches
    }

    /// Smooth-scroll so the match row sits near the upper third of the viewport.
    func scrollToSearchMatch(_ match: SearchMatch) {
        let snap = queryScrollbar()
        let maxO = snap?.maxOffset ?? scrollMaxOffset
        let vp = max(1, Double(snap?.len ?? UInt64(rows)))
        scrollMaxOffset = maxO
        scrollViewportRows = vp
        let target = Double(match.screenY) - vp * 0.25
        scrollPhysics.smoothTo(offset: target, maxOffset: maxO)
        // Integer viewport updates each frame via stepScroll while seeking.
        syncIntegerViewport()
    }

    /// Refresh Kitty placement geometry and textures (call on main after parse settles).
    func syncKittyGraphics(
        device: MTLDevice,
        layout: TerminalRenderer.LayoutKey,
        shellShiftY: Float,
        visualY: Float
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard isLive, let terminal else { return }
        kittyCache.sync(
            terminal: terminal,
            device: device,
            layout: layout,
            shellShiftY: shellShiftY,
            visualY: visualY
        )
    }

    /// Embeddable http(s) URL under a shell viewport cell (OSC 8, then bare text).
    func embeddableURLAtViewport(col: UInt16, row: UInt16) -> URL? {
        linkHitAtViewport(col: col, row: row)?.url
    }

    /// Full hit with column span for hover underline / open.
    /// OSC 8 path avoids a full-row text scan; bare http(s) scans one row only.
    func linkHitAtViewport(col: UInt16, row: UInt16) -> LinkResolve.Hit? {
        lock.lock()
        defer { lock.unlock() }
        guard isLive, let terminal else { return nil }
        let cCount = Int(cols)
        guard cCount > 0, Int(row) < Int(rows), Int(col) < cCount else { return nil }

        // Prefer OSC 8: only URI probes along the row for span expand.
        if let osc = LinkResolve.osc8URI(terminal: terminal, col: col, row: row),
           let url = LinkResolve.embeddableURL(from: osc) {
            let span = LinkResolve.osc8Span(
                terminal: terminal,
                col: Int(col),
                row: row,
                cols: cCount,
                uri: osc
            )
            return LinkResolve.Hit(url: url, startCol: span.start, endCol: span.end)
        }

        // Bare URL: one-row grapheme walk only when OSC misses.
        var cells = [String](repeating: "", count: cCount)
        var graphemeBuf = [UInt32](repeating: 0, count: 16)
        for c in 0..<cCount {
            var ref = GhosttyGridRef()
            ref.size = MemoryLayout<GhosttyGridRef>.size
            var point = GhosttyPoint()
            point.tag = GHOSTTY_POINT_TAG_VIEWPORT
            point.value.coordinate.x = UInt16(c)
            point.value.coordinate.y = UInt32(row)
            guard ghostty_terminal_grid_ref(terminal, point, &ref) == GHOSTTY_SUCCESS else {
                continue
            }
            var cell: GhosttyCell = 0
            guard ghostty_grid_ref_cell(&ref, &cell) == GHOSTTY_SUCCESS else { continue }
            var hasText = false
            _ = ghostty_cell_get(cell, GHOSTTY_CELL_DATA_HAS_TEXT, &hasText)
            guard hasText else { continue }
            var glen: Int = 0
            var gr = graphemeBuf.withUnsafeMutableBufferPointer { buf in
                ghostty_grid_ref_graphemes(&ref, buf.baseAddress, buf.count, &glen)
            }
            if gr == GHOSTTY_OUT_OF_SPACE, glen > graphemeBuf.count {
                graphemeBuf = [UInt32](repeating: 0, count: glen)
                gr = graphemeBuf.withUnsafeMutableBufferPointer { buf in
                    ghostty_grid_ref_graphemes(&ref, buf.baseAddress, buf.count, &glen)
                }
            }
            guard gr == GHOSTTY_SUCCESS, glen > 0 else { continue }
            let scalars = graphemeBuf.prefix(glen).compactMap { UnicodeScalar($0) }
            cells[c] = String(String.UnicodeScalarView(scalars))
        }
        if let bare = LinkResolve.bareHTTPHit(in: cells, atCol: Int(col)),
           let url = LinkResolve.embeddableURL(from: bare.raw) {
            return LinkResolve.Hit(url: url, startCol: bare.start, endCol: bare.end)
        }
        return nil
    }
}

// MARK: - Effects

final class EffectsBox {
    var ptyFD: Int32
    var cellWidth: Int32
    var cellHeight: Int32
    var cols: UInt16
    var rows: UInt16

    init(ptyFD: Int32, cellWidth: Int32, cellHeight: Int32, cols: UInt16, rows: UInt16) {
        self.ptyFD = ptyFD
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.cols = cols
        self.rows = rows
    }
}

private func effectWritePty(
    _ terminal: GhosttyTerminal?,
    _ userdata: UnsafeMutableRawPointer?,
    _ data: UnsafePointer<UInt8>?,
    _ len: Int
) {
    guard let userdata, let data, len > 0 else { return }
    let box = Unmanaged<EffectsBox>.fromOpaque(userdata).takeUnretainedValue()
    if box.ptyFD >= 0 {
        _ = ghosvt_pty_write_all(box.ptyFD, data, len)
    }
}

private func effectSize(
    _ terminal: GhosttyTerminal?,
    _ userdata: UnsafeMutableRawPointer?,
    _ outSize: UnsafeMutablePointer<GhosttySizeReportSize>?
) -> Bool {
    guard let userdata, let outSize else { return false }
    let box = Unmanaged<EffectsBox>.fromOpaque(userdata).takeUnretainedValue()
    outSize.pointee.rows = box.rows
    outSize.pointee.columns = box.cols
    outSize.pointee.cell_width = UInt32(box.cellWidth)
    outSize.pointee.cell_height = UInt32(box.cellHeight)
    return true
}

private func effectDeviceAttributes(
    _ terminal: GhosttyTerminal?,
    _ userdata: UnsafeMutableRawPointer?,
    _ outAttrs: UnsafeMutablePointer<GhosttyDeviceAttributes>?
) -> Bool {
    guard let outAttrs else { return false }
    // Rich DA1 feature set aligned with modern xterm/Ghostty-class terminals.
    outAttrs.pointee.primary.conformance_level = UInt16(GHOSTTY_DA_CONFORMANCE_VT220)
    outAttrs.pointee.primary.features.0 = UInt16(GHOSTTY_DA_FEATURE_COLUMNS_132)
    outAttrs.pointee.primary.features.1 = UInt16(GHOSTTY_DA_FEATURE_SELECTIVE_ERASE)
    outAttrs.pointee.primary.features.2 = UInt16(GHOSTTY_DA_FEATURE_ANSI_COLOR)
    outAttrs.pointee.primary.features.3 = UInt16(GHOSTTY_DA_FEATURE_RECTANGULAR_EDITING)
    outAttrs.pointee.primary.features.4 = UInt16(GHOSTTY_DA_FEATURE_CLIPBOARD)
    outAttrs.pointee.primary.num_features = 5
    outAttrs.pointee.secondary.device_type = UInt16(GHOSTTY_DA_DEVICE_TYPE_VT220)
    outAttrs.pointee.secondary.firmware_version = 1
    outAttrs.pointee.secondary.rom_cartridge = 0
    outAttrs.pointee.tertiary.unit_id = 0
    return true
}

private func effectXtversion(
    _ terminal: GhosttyTerminal?,
    _ userdata: UnsafeMutableRawPointer?
) -> GhosttyString {
    // Match Ghostty XTVERSION product name so apps that probe CSI > q
    // take the Ghostty code path (cursor hide, keybinds, etc.).
    let s: StaticString = "ghostty"
    return GhosttyString(
        ptr: UnsafeRawPointer(s.utf8Start).assumingMemoryBound(to: UInt8.self),
        len: s.utf8CodeUnitCount
    )
}

private func effectClipboardWrite(
    _ terminal: GhosttyTerminal?,
    _ userdata: UnsafeMutableRawPointer?,
    _ write: UnsafePointer<GhosttyClipboardWrite>?
) -> GhosttyClipboardWriteResult {
    _ = terminal
    _ = userdata
    guard let write else { return GHOSTTY_CLIPBOARD_WRITE_RESULT_INVALID_DATA }
    return Clipboard.applyClipboardWrite(write.pointee)
}
