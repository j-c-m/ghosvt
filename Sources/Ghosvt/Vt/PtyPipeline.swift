import Darwin
import Foundation

/// Two-stage PTY drain matching Ghostty Darwin Adaptive gather policy (WWDC-era IO work).
///
/// - **gather**: nonblocking `read`/`poll` into a ring of large buffers; spin-bridge
///   when the stream is saturated (≥1 KiB, macOS hands ~1 KiB per pty read).
/// - **parse**: consumes published batches on a dedicated thread via `onParse`.
///
/// Session owns the master fd and terminal lock; this type never closes the master.
final class PtyPipeline: @unchecked Sendable {
    // Ghostty Darwin defaults (`src/termio/Exec.zig` ReadThread).
    static let bufferCount = 4
    static let bufferCapacity = 64 * 1024
    static let bridgeThreshold = 1024
    static let bridgeSpinMax = 16
    static let bridgePollTimeoutMs: Int32 = 1
    static let gatherBudgetNs: UInt64 = 3_000_000 // 3 ms

    /// Invoked on the parse thread for each published batch (not on main).
    typealias ParseHandler = (UnsafePointer<UInt8>, Int) -> Void
    /// Invoked once on the parse thread after the stream ends (EOF/EIO/quit).
    typealias DeathHandler = () -> Void

    private let masterFD: Int32
    private let onParse: ParseHandler
    private let onDeath: DeathHandler

    private var quitReadFD: Int32 = -1
    private var quitWriteFD: Int32 = -1
    private var idleReadFD: Int32 = -1
    private var idleWriteFD: Int32 = -1

    private let slots: [UnsafeMutablePointer<UInt8>]
    private var lengths: [Int]
    private var head = 0
    private var tail = 0
    private var count = 0
    private var done = false
    private var bridging = false
    /// Gather saw EOF/EIO; parse sets `recoverReady` after draining the ring.
    private var streamEnded = false
    private var recoverReady = false

    private let ring = NSCondition()
    private var gatherThread: Thread?
    private var parseThread: Thread?
    private var started = false

    init(masterFD: Int32, onParse: @escaping ParseHandler, onDeath: @escaping DeathHandler) {
        self.masterFD = masterFD
        self.onParse = onParse
        self.onDeath = onDeath
        var bufs: [UnsafeMutablePointer<UInt8>] = []
        bufs.reserveCapacity(Self.bufferCount)
        for _ in 0..<Self.bufferCount {
            bufs.append(.allocate(capacity: Self.bufferCapacity))
        }
        slots = bufs
        lengths = [Int](repeating: 0, count: Self.bufferCount)
    }

    deinit {
        stop()
        for p in slots {
            p.deallocate()
        }
    }

    /// Start gather + parse threads. Idempotent.
    /// - Returns: `false` if the quit pipe could not be created (no threads started).
    @discardableResult
    func start() -> Bool {
        ring.lock()
        if started {
            ring.unlock()
            return true
        }
        ring.unlock()

        var fds = [Int32](repeating: -1, count: 2)
        guard pipe(&fds) == 0 else {
            fputs("ghosvt: PtyPipeline quit pipe failed\n", stderr)
            return false
        }
        quitReadFD = fds[0]
        quitWriteFD = fds[1]
        setNonBlocking(quitReadFD)
        setNonBlocking(quitWriteFD)

        // Idle wake is optional; bridge still works without it (latency only).
        if pipe(&fds) == 0 {
            idleReadFD = fds[0]
            idleWriteFD = fds[1]
            setNonBlocking(idleReadFD)
            setNonBlocking(idleWriteFD)
        }

        let gather = Thread { [weak self] in
            self?.gatherMain()
        }
        gather.name = "ghosvt-io-gather"
        gather.qualityOfService = .userInteractive
        gatherThread = gather

        let parse = Thread { [weak self] in
            self?.parseMain()
        }
        parse.name = "ghosvt-io-parse"
        parse.qualityOfService = .userInteractive
        parseThread = parse

        ring.lock()
        started = true
        ring.unlock()

        gather.start()
        parse.start()
        return true
    }

    /// Signal quit, join threads, close control pipes. Safe to call multiple times.
    /// Must not be called while holding the session lock that `onParse` takes.
    func stop() {
        ring.lock()
        guard started else {
            ring.unlock()
            return
        }
        done = true
        ring.broadcast()
        ring.unlock()

        if quitWriteFD >= 0 {
            var b: UInt8 = 1
            _ = write(quitWriteFD, &b, 1)
        }
        wakeIdle()

        gatherThread?.cancel()
        parseThread?.cancel()
        // Thread.join is not available; wait via condition until both exit flags set.
        // Use synchronous join pattern: threads check done and exit; poll briefly.
        if let t = gatherThread, t !== Thread.current {
            while !t.isFinished {
                Thread.sleep(forTimeInterval: 0.0005)
            }
        }
        if let t = parseThread, t !== Thread.current {
            while !t.isFinished {
                Thread.sleep(forTimeInterval: 0.0005)
            }
        }
        gatherThread = nil
        parseThread = nil

        closeFD(&quitReadFD)
        closeFD(&quitWriteFD)
        closeFD(&idleReadFD)
        closeFD(&idleWriteFD)

        ring.lock()
        started = false
        head = 0
        tail = 0
        count = 0
        done = false
        bridging = false
        streamEnded = false
        // keep recoverReady for the session to observe after stop
        ring.unlock()
    }

    /// True once after the stream ends and parse has drained (or stop after EOF).
    func takeChildDead() -> Bool {
        ring.lock()
        defer { ring.unlock() }
        if recoverReady {
            recoverReady = false
            return true
        }
        return false
    }

    // MARK: - Parse stage

    private func parseMain() {
        while true {
            let batch: (UnsafeMutablePointer<UInt8>, Int)? = {
                ring.lock()
                defer { ring.unlock() }
                while count == 0 && !done {
                    ring.wait()
                }
                if count == 0 {
                    return nil
                }
                let slot = tail
                let len = lengths[slot]
                let ptr = slots[slot]
                // Hand ownership of bytes to parse without copying; ring slot
                // stays reserved until we advance tail after onParse.
                return (ptr, len)
            }()

            guard let (ptr, len) = batch else {
                ring.lock()
                if streamEnded {
                    recoverReady = true
                }
                ring.unlock()
                onDeath()
                return
            }

            if len > 0 {
                onParse(UnsafePointer(ptr), len)
            }

            ring.lock()
            tail = (tail + 1) % Self.bufferCount
            count -= 1
            let nowIdle = count == 0
            let wasBridging = bridging
            ring.broadcast()
            ring.unlock()

            // Ghostty #13237: if gather is bridge-sleeping and we went idle,
            // interrupt so it delivers immediately (request/response latency).
            if nowIdle && wasBridging {
                wakeIdle()
            }
        }
    }

    // MARK: - Gather stage

    private func gatherMain() {
        defer {
            ring.lock()
            done = true
            ring.broadcast()
            ring.unlock()
        }

        while true {
            // Claim free slot (backpressure when ring full).
            let slotIndex: Int = {
                ring.lock()
                defer { ring.unlock() }
                while count == Self.bufferCount && !done {
                    ring.wait()
                }
                // Quit or stream end: do not claim another slot.
                if done { return -1 }
                return head
            }()
            if slotIndex < 0 { return }

            let buf = slots[slotIndex]
            var total = 0
            var bridgeStart: UInt64?
            var spins = 0
            var fatal = false
            var sawEOF = false

            gatherLoop: while total < Self.bufferCapacity {
                if Thread.current.isCancelled {
                    fatal = true
                    break gatherLoop
                }

                let n = read(masterFD, buf.advanced(by: total), Self.bufferCapacity - total)
                if n > 0 {
                    total += Int(n)
                    spins = 0
                    continue gatherLoop
                }
                if n == 0 {
                    sawEOF = true
                    fatal = true
                    break gatherLoop
                }

                let err = errno
                if err == EINTR {
                    continue gatherLoop
                }
                if err == EAGAIN || err == EWOULDBLOCK {
                    // Interactive: deliver what we have without bridging.
                    if total < Self.bridgeThreshold {
                        break gatherLoop
                    }

                    // Saturated stream: spin then short poll (Ghostty bridge).
                    if spins < Self.bridgeSpinMax {
                        spins += 1
                        continue gatherLoop
                    }

                    let now = machContinuousTimeNs()
                    if let start = bridgeStart {
                        if now &- start >= Self.gatherBudgetNs {
                            break gatherLoop
                        }
                    } else {
                        bridgeStart = now
                    }

                    // Only bridge-sleep while parse still has work; if parse is
                    // idle, deliver now (avoids holding a query in the batch).
                    let shouldBridge: Bool = {
                        ring.lock()
                        defer { ring.unlock() }
                        if count == 0 { return false }
                        bridging = true
                        return true
                    }()
                    if !shouldBridge {
                        break gatherLoop
                    }

                    var pollfds = [
                        pollfd(fd: masterFD, events: Int16(POLLIN), revents: 0),
                        pollfd(fd: quitReadFD, events: Int16(POLLIN), revents: 0),
                    ]
                    if idleReadFD >= 0 {
                        pollfds.append(pollfd(fd: idleReadFD, events: Int16(POLLIN), revents: 0))
                    }
                    let pr = poll(&pollfds, nfds_t(pollfds.count), Self.bridgePollTimeoutMs)
                    clearBridging()

                    if pr == 0 {
                        // Quiet for full timeout — burst ended.
                        break gatherLoop
                    }
                    if pr < 0 {
                        if errno == EINTR { continue gatherLoop }
                        fatal = true
                        break gatherLoop
                    }
                    if pollfds[1].revents & Int16(POLLIN) != 0 {
                        fatal = true
                        break gatherLoop
                    }
                    if idleReadFD >= 0,
                       pollfds.count > 2,
                       pollfds[2].revents & Int16(POLLIN) != 0 {
                        drainIdle()
                        // Parser went idle: deliver immediately.
                        break gatherLoop
                    }
                    // Master readable: continue gathering.
                    spins = 0
                    continue gatherLoop
                }
                if err == EIO {
                    sawEOF = true
                    fatal = true
                    break gatherLoop
                }
                fatal = true
                break gatherLoop
            }

            clearBridging()

            // Publish batch (including empty only when finishing).
            ring.lock()
            if total > 0 {
                lengths[slotIndex] = total
                head = (head + 1) % Self.bufferCount
                count += 1
                ring.broadcast()
            }
            if sawEOF {
                streamEnded = true
            }
            if fatal {
                done = true
                if sawEOF { streamEnded = true }
                ring.broadcast()
                ring.unlock()
                return
            }
            ring.unlock()

            if total == 0 {
                // Wait for master or quit.
                var pollfds = [
                    pollfd(fd: masterFD, events: Int16(POLLIN), revents: 0),
                    pollfd(fd: quitReadFD, events: Int16(POLLIN), revents: 0),
                ]
                let pr = poll(&pollfds, 2, -1)
                if pr < 0 {
                    if errno == EINTR { continue }
                    ring.lock()
                    done = true
                    streamEnded = true
                    ring.broadcast()
                    ring.unlock()
                    return
                }
                if pollfds[1].revents & Int16(POLLIN) != 0 {
                    ring.lock()
                    done = true
                    ring.broadcast()
                    ring.unlock()
                    return
                }
                if pollfds[0].revents & Int16(POLLHUP) != 0 {
                    ring.lock()
                    done = true
                    streamEnded = true
                    ring.broadcast()
                    ring.unlock()
                    return
                }
            }
        }
    }

    // MARK: - Helpers

    private func clearBridging() {
        ring.lock()
        bridging = false
        ring.unlock()
    }

    private func wakeIdle() {
        guard idleWriteFD >= 0 else { return }
        var b: UInt8 = 1
        _ = write(idleWriteFD, &b, 1)
    }

    private func drainIdle() {
        guard idleReadFD >= 0 else { return }
        var buf = [UInt8](repeating: 0, count: 64)
        while read(idleReadFD, &buf, buf.count) > 0 {}
    }

    private func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
    }

    private func closeFD(_ fd: inout Int32) {
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Nanoseconds from `mach_continuous_time` (advances across sleep).
    private func machContinuousTimeNs() -> UInt64 {
        let t = mach_continuous_time()
        let tb = Self.timebase
        return t * UInt64(tb.numer) / UInt64(tb.denom)
    }
}
