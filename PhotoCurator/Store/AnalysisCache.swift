import Foundation
import SQLite3
import os

/// On-disk analysis cache (PRD §3, §5): keyed by asset local identifier plus
/// modification date so an edited photo is re-analysed and everything else is
/// read straight back. This is what makes the <2 minute rescan target
/// in PRD §13 reachable.
///
/// Plain SQLite rather than SwiftData: the hot path is a single bulk read of
/// ~10k rows at launch and batched writes during the scan, and we want explicit
/// control over the transaction boundaries.
/// Not actually thread-safe on its own (it wraps one raw SQLite connection
/// via `db: OpaquePointer?`, mutated in place by every call). Marked
/// `@unchecked Sendable` because every call in this app is funneled through
/// the `@MainActor`-isolated `LibraryScanner` or awaited sequentially inside
/// a single `Task`, so calls are never actually concurrent. If a second
/// caller is ever added outside that path, this needs a real actor or a lock.
final class AnalysisCache: @unchecked Sendable {

    enum CacheError: Error, LocalizedError {
        case openFailed(String)
        case statementFailed(String)

        var errorDescription: String? {
            switch self {
            case .openFailed(let m): return "Could not open the analysis cache: \(m)"
            case .statementFailed(let m): return "Analysis cache query failed: \(m)"
            }
        }
    }

    private var db: OpaquePointer?
    private let log = Logger(subsystem: "app.photocurator", category: "cache")
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Bump when the analysis itself changes meaning, to invalidate every row.
    static let schemaVersion = 1

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("PhotoCurator", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("analysis.sqlite")
    }

    init(url: URL = AnalysisCache.defaultURL) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw CacheError.openFailed(msg)
        }
        self.db = handle
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA synchronous=NORMAL;")
        try createSchema()
    }

    deinit { if let db { sqlite3_close_v2(db) } }

    // MARK: Schema

    private func createSchema() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS meta (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """)
        try exec("""
        CREATE TABLE IF NOT EXISTS photo (
            id        TEXT PRIMARY KEY,
            mod_date  REAL,
            payload   BLOB NOT NULL
        );
        """)
        try exec("""
        CREATE TABLE IF NOT EXISTS confirmed_keep (
            id TEXT PRIMARY KEY
        );
        """)
        // PRD §9.5: local deletion log. Written in M5, defined now so the
        // schema does not change under an existing cache later.
        try exec("""
        CREATE TABLE IF NOT EXISTS deletion_log (
            id       TEXT NOT NULL,
            tier     INTEGER NOT NULL,
            reason   TEXT NOT NULL,
            deleted_at REAL NOT NULL
        );
        """)
        // User-confirmed trips (simplified PRD §11 Book). One row per trip,
        // the whole struct stored as JSON since it is small and read/written
        // as a unit.
        try exec("""
        CREATE TABLE IF NOT EXISTS trip (
            id      TEXT PRIMARY KEY,
            payload BLOB NOT NULL
        );
        """)

        let stored = Int(value(forMetaKey: "schema_version") ?? "0") ?? 0
        if stored != Self.schemaVersion {
            log.notice("Cache schema \(stored) -> \(Self.schemaVersion); clearing analysis rows")
            try exec("DELETE FROM photo;")
            try setMeta("schema_version", String(Self.schemaVersion))
        }
    }

    // MARK: Reads

    /// Loads every cached record keyed by id. One pass, used at scan start.
    func loadAll() throws -> [String: PhotoRecord] {
        var out: [String: PhotoRecord] = [:]
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload FROM photo;", -1, &stmt, nil) == SQLITE_OK else {
            throw CacheError.statementFailed(lastErrorMessage)
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(stmt, 0) else { continue }
            let count = Int(sqlite3_column_bytes(stmt, 0))
            let data = Data(bytes: bytes, count: count)
            if let record = try? decoder.decode(PhotoRecord.self, from: data) {
                out[record.id] = record
            }
        }
        return out
    }

    func confirmedKeepIds() throws -> Set<String> {
        var out = Set<String>()
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id FROM confirmed_keep;", -1, &stmt, nil) == SQLITE_OK else {
            throw CacheError.statementFailed(lastErrorMessage)
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { out.insert(String(cString: c)) }
        }
        return out
    }

    // MARK: Writes

    /// Upserts a batch inside one transaction. The scanner calls this every
    /// few hundred photos so a cancelled scan keeps its progress (PRD §4.3:
    /// resumable).
    func save(_ records: [PhotoRecord]) throws {
        guard !records.isEmpty else { return }
        try exec("BEGIN IMMEDIATE;")
        var committed = false
        defer { if !committed { try? exec("ROLLBACK;") } }

        var stmt: OpaquePointer?
        let sql = "INSERT INTO photo (id, mod_date, payload) VALUES (?, ?, ?) " +
                  "ON CONFLICT(id) DO UPDATE SET mod_date=excluded.mod_date, payload=excluded.payload;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw CacheError.statementFailed(lastErrorMessage)
        }
        defer { sqlite3_finalize(stmt) }

        for record in records {
            let data = try encoder.encode(record)
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            sqlite3_bind_text(stmt, 1, record.id, -1, SQLITE_TRANSIENT)
            if let mod = record.modificationDate {
                sqlite3_bind_double(stmt, 2, mod.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(stmt, 2)
            }
            try data.withUnsafeBytes { raw in
                sqlite3_bind_blob(stmt, 3, raw.baseAddress, Int32(raw.count), SQLITE_TRANSIENT)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw CacheError.statementFailed(lastErrorMessage)
                }
            }
        }
        try exec("COMMIT;")
        committed = true
    }

    /// PRD §6, Tier 3: "Keep all" locks photos out of future scans.
    func confirmKeep(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try exec("BEGIN IMMEDIATE;")
        var committed = false
        defer { if !committed { try? exec("ROLLBACK;") } }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO confirmed_keep (id) VALUES (?);",
                                 -1, &stmt, nil) == SQLITE_OK else {
            throw CacheError.statementFailed(lastErrorMessage)
        }
        defer { sqlite3_finalize(stmt) }
        for id in ids {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw CacheError.statementFailed(lastErrorMessage)
            }
        }
        try exec("COMMIT;")
        committed = true
    }

    // MARK: Trips

    /// All saved trips, newest-created first.
    func loadTrips() throws -> [Trip] {
        var out: [Trip] = []
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload FROM trip ORDER BY rowid DESC;",
                                 -1, &stmt, nil) == SQLITE_OK else {
            throw CacheError.statementFailed(lastErrorMessage)
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(stmt, 0) else { continue }
            let count = Int(sqlite3_column_bytes(stmt, 0))
            let data = Data(bytes: bytes, count: count)
            if let trip = try? decoder.decode(Trip.self, from: data) { out.append(trip) }
        }
        return out
    }

    func saveTrip(_ trip: Trip) throws {
        let data = try encoder.encode(trip)
        var stmt: OpaquePointer?
        let sql = "INSERT INTO trip (id, payload) VALUES (?, ?) " +
                  "ON CONFLICT(id) DO UPDATE SET payload=excluded.payload;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw CacheError.statementFailed(lastErrorMessage)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, trip.id, -1, SQLITE_TRANSIENT)
        try data.withUnsafeBytes { raw in
            sqlite3_bind_blob(stmt, 2, raw.baseAddress, Int32(raw.count), SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw CacheError.statementFailed(lastErrorMessage)
            }
        }
    }

    func deleteTrip(id: String) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM trip WHERE id = ?;", -1, &stmt, nil) == SQLITE_OK else {
            throw CacheError.statementFailed(lastErrorMessage)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw CacheError.statementFailed(lastErrorMessage)
        }
    }

    /// PRD §9.5: local deletion log, written *before* the PhotoKit call so a
    /// crash mid-deletion still leaves a record of what was requested.
    func logDeletion(ids: [String], tier: Tier, reason: TierReason, at date: Date = Date()) throws {
        guard !ids.isEmpty else { return }
        try exec("BEGIN IMMEDIATE;")
        var committed = false
        defer { if !committed { try? exec("ROLLBACK;") } }
        var stmt: OpaquePointer?
        let sql = "INSERT INTO deletion_log (id, tier, reason, deleted_at) VALUES (?, ?, ?, ?);"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw CacheError.statementFailed(lastErrorMessage)
        }
        defer { sqlite3_finalize(stmt) }
        for id in ids {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(tier.rawValue))
            sqlite3_bind_text(stmt, 3, reason.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 4, date.timeIntervalSince1970)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw CacheError.statementFailed(lastErrorMessage)
            }
        }
        try exec("COMMIT;")
        committed = true
    }

    struct DeletionLogEntry {
        var id: String
        var tier: Tier
        var reason: TierReason
        var deletedAt: Date
    }

    /// All deletion-log rows, newest first. Used by the undo hint and any
    /// future "what did I delete" view.
    func deletionLog() throws -> [DeletionLogEntry] {
        var out: [DeletionLogEntry] = []
        var stmt: OpaquePointer?
        let sql = "SELECT id, tier, reason, deleted_at FROM deletion_log ORDER BY deleted_at DESC;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw CacheError.statementFailed(lastErrorMessage)
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idC = sqlite3_column_text(stmt, 0),
                  let reasonC = sqlite3_column_text(stmt, 2) else { continue }
            let tierRaw = Int(sqlite3_column_int(stmt, 1))
            guard let tier = Tier(rawValue: tierRaw),
                  let reason = TierReason(rawValue: String(cString: reasonC)) else { continue }
            let date = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
            out.append(DeletionLogEntry(id: String(cString: idC), tier: tier,
                                        reason: reason, deletedAt: date))
        }
        return out
    }

    /// Removes rows for photos that were deleted, so they do not reappear as
    /// stale entries on the next scan. The deletion log row is kept.
    func removePhotoRows(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        for chunk in ids.chunked(into: 400) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM photo WHERE id IN (\(placeholders));",
                                     -1, &stmt, nil) == SQLITE_OK else {
                throw CacheError.statementFailed(lastErrorMessage)
            }
            defer { sqlite3_finalize(stmt) }
            for (i, id) in chunk.enumerated() {
                sqlite3_bind_text(stmt, Int32(i + 1), id, -1, SQLITE_TRANSIENT)
            }
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw CacheError.statementFailed(lastErrorMessage)
            }
        }
    }

    /// Drops rows for assets no longer in the library.
    func prune(keeping liveIds: Set<String>) throws {
        let cached = try loadAll().keys
        let stale = cached.filter { !liveIds.contains($0) }
        guard !stale.isEmpty else { return }
        for chunk in Array(stale).chunked(into: 400) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM photo WHERE id IN (\(placeholders));",
                                     -1, &stmt, nil) == SQLITE_OK else {
                throw CacheError.statementFailed(lastErrorMessage)
            }
            defer { sqlite3_finalize(stmt) }
            for (i, id) in chunk.enumerated() {
                sqlite3_bind_text(stmt, Int32(i + 1), id, -1, SQLITE_TRANSIENT)
            }
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw CacheError.statementFailed(lastErrorMessage)
            }
        }
        log.notice("Pruned \(stale.count) stale cache rows")
    }

    func clear() throws {
        try exec("DELETE FROM photo;")
    }

    // MARK: Meta helpers

    func value(forMetaKey key: String) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = ?;", -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: c)
    }

    func setMeta(_ key: String, _ value: String) throws {
        var stmt: OpaquePointer?
        let sql = "INSERT INTO meta (key, value) VALUES (?, ?) " +
                  "ON CONFLICT(key) DO UPDATE SET value=excluded.value;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw CacheError.statementFailed(lastErrorMessage)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, value, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw CacheError.statementFailed(lastErrorMessage)
        }
    }

    // MARK: Plumbing

    private var lastErrorMessage: String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "no database"
    }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? lastErrorMessage
            sqlite3_free(err)
            throw CacheError.statementFailed(msg)
        }
    }
}

/// SQLITE_TRANSIENT is a macro Swift does not import.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
