import Foundation
import SQLite3

/// Persistent visit log for the embedded browser (URL autocomplete).
///
/// SQLite under Application Support/ghosvt. Main-thread friendly API; work is
/// serialized on an internal queue.
final class BrowserHistory: @unchecked Sendable {
    static let shared = BrowserHistory()

    struct Entry: Equatable, Sendable {
        var url: String
        var title: String
        var visitCount: Int
        var lastVisit: Date
    }

    /// Soft cap; oldest by last_visit drop first.
    private static let maxEntries = 10_000
    /// Drop visits older than this (seconds).
    private static let maxAge: TimeInterval = 180 * 24 * 60 * 60

    private let queue = DispatchQueue(label: "ghosvt.browser.history")
    private var db: OpaquePointer?

    private init() {
        queue.sync {
            openDatabase()
            prune()
        }
    }

    deinit {
        queue.sync {
            if let db {
                sqlite3_close(db)
            }
        }
    }

    // MARK: - Public

    /// Record a finished navigation (http/https only). Upserts by normalized URL.
    /// Call once per successful load (`didFinish`) — not on address commit.
    func record(url: URL, title: String?) {
        guard let key = Self.storageKey(for: url) else { return }
        let title = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date().timeIntervalSince1970
        queue.async { [weak self] in
            self?.upsert(url: key, title: title, now: now)
        }
    }

    /// Best single URL to complete `typed` (prefix match), if any.
    /// Returns full URL and the index where the suggestion suffix begins.
    func completion(for typed: String) -> (url: String, selectFrom: Int)? {
        let partial = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard partial.count >= 1 else { return nil }
        return queue.sync {
            Self.pickCompletion(partial: partial, candidates: queryCandidates(partial: partial, limit: 40))
        }
    }

    /// Up to `limit` matching history entries for UI lists.
    func suggestions(for typed: String, limit: Int = 12) -> [Entry] {
        let partial = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard partial.count >= 1 else { return [] }
        return queue.sync {
            queryCandidates(partial: partial, limit: max(1, limit))
        }
    }

    // MARK: - Open

    private func openDatabase() {
        let fm = FileManager.default
        guard let base = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            fputs("ghosvt: browser history: no Application Support\n", stderr)
            return
        }
        let dir = base.appendingPathComponent("ghosvt", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("browser-history.sqlite").path
        var handle: OpaquePointer?
        if sqlite3_open(path, &handle) != SQLITE_OK {
            fputs("ghosvt: browser history: open failed \(path)\n", stderr)
            if let handle { sqlite3_close(handle) }
            return
        }
        db = handle
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA busy_timeout=3000;")
        exec("""
            CREATE TABLE IF NOT EXISTS history (
                url TEXT PRIMARY KEY NOT NULL,
                title TEXT NOT NULL DEFAULT '',
                visit_count INTEGER NOT NULL DEFAULT 1,
                last_visit REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_history_last ON history(last_visit DESC);
            CREATE INDEX IF NOT EXISTS idx_history_url ON history(url);
            """)
        fputs("ghosvt: browser history \(path)\n", stderr)
    }

    private func exec(_ sql: String) {
        guard let db else { return }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "?"
            sqlite3_free(err)
            fputs("ghosvt: browser history SQL: \(msg)\n", stderr)
        }
    }

    // MARK: - Write / read

    private func upsert(url: String, title: String, now: Double) {
        guard let db else { return }
        let sql = """
            INSERT INTO history (url, title, visit_count, last_visit)
            VALUES (?, ?, 1, ?)
            ON CONFLICT(url) DO UPDATE SET
                title = CASE WHEN excluded.title != '' THEN excluded.title ELSE history.title END,
                visit_count = history.visit_count + 1,
                last_visit = excluded.last_visit;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, url, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, title, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 3, now)
        if sqlite3_step(stmt) != SQLITE_DONE {
            fputs("ghosvt: browser history upsert failed\n", stderr)
        }
    }

    /// Age + size cap; called once at open.
    private func prune() {
        guard let db else { return }

        let cutoff = Date().timeIntervalSince1970 - Self.maxAge
        var ageStmt: OpaquePointer?
        if sqlite3_prepare_v2(
            db,
            "DELETE FROM history WHERE last_visit < ?;",
            -1,
            &ageStmt,
            nil
        ) == SQLITE_OK, let ageStmt {
            defer { sqlite3_finalize(ageStmt) }
            sqlite3_bind_double(ageStmt, 1, cutoff)
            _ = sqlite3_step(ageStmt)
        }

        let sql = """
            DELETE FROM history WHERE rowid NOT IN (
                SELECT rowid FROM history ORDER BY last_visit DESC LIMIT ?
            );
            """
        var capStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &capStmt, nil) == SQLITE_OK, let capStmt {
            defer { sqlite3_finalize(capStmt) }
            sqlite3_bind_int(capStmt, 1, Int32(Self.maxEntries))
            _ = sqlite3_step(capStmt)
        }
    }

    private func queryCandidates(partial: String, limit: Int) -> [Entry] {
        guard let db else { return [] }
        // Match: URL prefix, or scheme-stripped prefix, ordered by use.
        let sql = """
            SELECT url, title, visit_count, last_visit FROM history
            WHERE url LIKE ? ESCAPE '\\'
               OR url LIKE ? ESCAPE '\\'
               OR url LIKE ? ESCAPE '\\'
            ORDER BY visit_count DESC, last_visit DESC
            LIMIT ?;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }

        let escaped = Self.escapeLike(partial)
        let p1 = "\(escaped)%"
        let p2 = "https://\(escaped)%"
        let p3 = "http://\(escaped)%"
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, p1, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, p2, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, p3, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 4, Int32(limit))

        var out: [Entry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let urlPtr = sqlite3_column_text(stmt, 0),
                  let titlePtr = sqlite3_column_text(stmt, 1) else { continue }
            let url = String(cString: urlPtr)
            let title = String(cString: titlePtr)
            let count = Int(sqlite3_column_int(stmt, 2))
            let last = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
            out.append(Entry(url: url, title: title, visitCount: count, lastVisit: last))
        }
        return out
    }

    // MARK: - Matching

    private static func pickCompletion(
        partial: String,
        candidates: [Entry]
    ) -> (url: String, selectFrom: Int)? {
        let lower = partial.lowercased()
        // Prefer exact URL-prefix matches (typed includes scheme).
        for e in candidates {
            let u = e.url
            if u.lowercased().hasPrefix(lower) {
                guard u.count > partial.count else { continue }
                return (u, partial.count)
            }
        }
        // Typed host/path without scheme → complete to full https URL.
        for e in candidates {
            let u = e.url
            let stripped = stripScheme(u).lowercased()
            if stripped.hasPrefix(lower) {
                if let range = u.lowercased().range(of: lower) {
                    let from = u.distance(from: u.startIndex, to: range.upperBound)
                    if from < u.count {
                        return (u, from)
                    }
                }
                let selectFrom = min(u.count, max(partial.count, 0))
                if u.count > selectFrom {
                    return (u, selectFrom)
                }
            }
        }
        return nil
    }

    private static func stripScheme(_ url: String) -> String {
        if let r = url.range(of: "://") {
            return String(url[r.upperBound...])
        }
        return url
    }

    private static func escapeLike(_ s: String) -> String {
        s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    // MARK: - Normalize

    /// Persistable http(s) URL string, or nil to skip.
    private static func storageKey(for url: URL) -> String? {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        guard let rawScheme = c.scheme?.lowercased() else { return nil }
        switch rawScheme {
        case "http", "https":
            c.scheme = rawScheme
        default:
            return nil
        }
        guard var host = c.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasSuffix(".") {
            host = String(host.dropLast())
        }
        guard !host.isEmpty else { return nil }
        c.host = host
        c.fragment = nil

        if let port = c.port {
            if (rawScheme == "http" && port == 80) || (rawScheme == "https" && port == 443) {
                c.port = nil
            }
        }

        // Collapse trailing slash on non-root paths (`/foo/` → `/foo`).
        var path = c.path
        if path.count > 1, path.hasSuffix("/") {
            path = String(path.dropLast())
        }
        c.path = path

        if let items = c.queryItems, !items.isEmpty {
            let kept = items.filter { !isTrackingQueryName($0.name) }
            c.queryItems = kept.isEmpty ? nil : kept
        }

        return c.string ?? c.url?.absoluteString
    }

    private static let trackingQueryExact: Set<String> = [
        "gclid", "gbraid", "wbraid", "dclid", "gclsrc",
        "fbclid", "mc_cid", "mc_eid", "msclkid", "yclid", "twclid",
        "igshid", "_ga", "_gl", "si", "mkt_tok", "vero_id",
    ]

    private static func isTrackingQueryName(_ name: String) -> Bool {
        let n = name.lowercased()
        if n.hasPrefix("utm_") { return true }
        if trackingQueryExact.contains(n) { return true }
        return false
    }
}
