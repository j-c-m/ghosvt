import AppKit
import CGhosttyVT
import Darwin
import Foundation

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

    private var cols: UInt16 = 80
    private var rows: UInt16 = 24
    private var cellWidthPx: UInt32 = 8
    private var cellHeightPx: UInt32 = 16

    private let lock = NSLock()
    private let scrollbackLines: Int

    /// Last integer row pushed to `ghostty_terminal_scroll_viewport`.
    private var lastSyncedIntegerRow: UInt64?
    /// Cached scrollbar max offset (rows from top).
    private(set) var scrollMaxOffset: Double = 0
    private(set) var scrollViewportRows: Double = 24

    /// Persistent bytes for GHOSTTY_TERMINAL_OPT_TERMINFO_NAME.
    private let terminfoNameBytes: [UInt8] = Array("xterm-ghostty".utf8)

    /// Context for C effects callbacks (heap-stable).
    private var effectsBox: EffectsBox?

    init(index: Int, scrollbackLines: Int) {
        self.index = index
        self.scrollbackLines = scrollbackLines
    }

    /// Apply config spring/friction constants to this session's physics.
    func applyScrollConfig(_ config: Config) {
        scrollPhysics.springK = config.scrollSpringK
        scrollPhysics.springC = config.scrollSpringC
        scrollPhysics.friction = config.scrollFriction
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

    /// Drain PTY → vt_write. Respawns login if the child dies.
    /// Budgeted so one flood cannot stall the main thread indefinitely.
    func pollIO(maxBytes: Int = 256 * 1024, maxReads: Int = 32) {
        lock.lock()
        defer { lock.unlock() }
        guard isLive, let terminal, masterFD >= 0 else { return }

        var buf = [UInt8](repeating: 0, count: 8192)
        var childDead = false
        var total = 0
        var reads = 0
        while reads < maxReads, total < maxBytes {
            reads += 1
            let n = read(masterFD, &buf, buf.count)
            if n > 0 {
                ghostty_terminal_vt_write(terminal, buf, Int(n))
                total += Int(n)
                continue
            }
            if n == 0 {
                childDead = true
                break
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                break
            }
            if errno == EINTR {
                continue
            }
            if errno == EIO {
                childDead = true
                break
            }
            break
        }

        if childDead {
            respawnLocked()
            return
        }
        if childPID > 0 {
            var status: Int32 = 0
            let r = waitpid(childPID, &status, WNOHANG)
            if r == childPID {
                respawnLocked()
            }
        }
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

    /// Two-phase render-state update: hold the session lock only for begin.
    func updateRenderState() {
        lock.lock()
        guard let terminal, let renderState else {
            lock.unlock()
            return
        }
        _ = ghostty_render_state_begin_update(renderState, terminal)
        lock.unlock()
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
        guard isLive, let terminal else { return false }
        var tracking = false
        _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &tracking)
        return tracking
    }

    /// Wheel/trackpad impulse. Positive `deltaRows` moves toward older history (lower offset).
    func applyScrollImpulse(deltaRows: Double) {
        scrollPhysics.applyImpulse(deltaRows: deltaRows)
    }

    /// Fractional pixel shift in row units for the renderer.
    func visualOffsetRows() -> Double {
        scrollPhysics.visualOffsetRows(maxOffset: scrollMaxOffset)
    }

    /// Integrate physics, pin-follow, and push integer viewport to ghostty.
    /// Returns true while the spring/coast still needs frames.
    @discardableResult
    func stepScroll(dt: Double) -> Bool {
        guard isLive else { return false }

        let snap = queryScrollbar()
        let maxO = snap?.maxOffset ?? 0
        let vpRows = Double(snap?.len ?? UInt64(rows))
        scrollMaxOffset = maxO
        scrollViewportRows = max(1, vpRows)

        // New output grows history: stay glued when pinned.
        scrollPhysics.followBottomIfPinned(maxOffset: maxO)

        // Clamp if scrollback was trimmed under us.
        if !scrollPhysics.pinnedToBottom, scrollPhysics.position > maxO {
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

        var lines = scrollbackLines
        withUnsafePointer(to: &lines) { ptr in
            _ = ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, UnsafeRawPointer(ptr))
        }
        // Default theme so login banner is visible before any OSC colors.
        var fg = GhosttyColorRgb(r: 230, g: 230, b: 230)
        var bg = GhosttyColorRgb(r: 12, g: 12, b: 16)
        withUnsafePointer(to: &fg) { ptr in
            _ = ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, UnsafeRawPointer(ptr))
        }
        withUnsafePointer(to: &bg) { ptr in
            _ = ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, UnsafeRawPointer(ptr))
        }

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

        installEffectsLocked()
        spawnLoginLocked()
        isLive = true
    }

    private func spawnLoginLocked() {
        var pid: pid_t = -1
        let fd: Int32
        if let path = Terminfo.databasePath {
            fd = path.withCString { cPath in
                ghosvt_pty_spawn_login(
                    Int32(index),
                    cols,
                    rows,
                    cellWidthPx,
                    cellHeightPx,
                    cPath,
                    &pid
                )
            }
        } else {
            fd = ghosvt_pty_spawn_login(
                Int32(index),
                cols,
                rows,
                cellWidthPx,
                cellHeightPx,
                nil,
                &pid
            )
        }
        if fd < 0 {
            let err = String(cString: strerror(errno))
            fputs("ghosvt: forkpty/login failed for ttyv\(index): \(err)\n", stderr)
            masterFD = -1
            childPID = -1
            return
        }
        masterFD = fd
        childPID = pid
        effectsBox?.ptyFD = fd
    }

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
        }
        lastSyncedIntegerRow = nil
        scrollMaxOffset = 0
        scrollPhysics.pinBottom(maxOffset: 0)
        spawnLoginLocked()
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
    }

    private func setFn<T>(_ terminal: GhosttyTerminal, _ opt: GhosttyTerminalOption, _ fn: T) {
        let ptr = unsafeBitCast(fn, to: UnsafeRawPointer.self)
        _ = ghostty_terminal_set(terminal, opt, ptr)
    }

    private func tearDown() {
        lock.lock()
        defer { lock.unlock() }
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
        if let keyEvent { ghostty_key_event_free(keyEvent) }
        if let keyEncoder { ghostty_key_encoder_free(keyEncoder) }
        if let rowCells { ghostty_render_state_row_cells_free(rowCells) }
        if let rowIterator { ghostty_render_state_row_iterator_free(rowIterator) }
        if let renderState { ghostty_render_state_free(renderState) }
        if let terminal { ghostty_terminal_free(terminal) }
        self.keyEvent = nil
        self.keyEncoder = nil
        self.rowCells = nil
        self.rowIterator = nil
        self.renderState = nil
        self.terminal = nil
        isLive = false
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
    let s: StaticString = "ghosvt"
    return GhosttyString(
        ptr: UnsafeRawPointer(s.utf8Start).assumingMemoryBound(to: UInt8.self),
        len: s.utf8CodeUnitCount
    )
}
