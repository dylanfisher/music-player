import Foundation
import SQLite3

/// One connection to a SQLite database file.
///
/// Threading: a connection is opened in SQLite's multi-thread mode, so it must never be used by
/// two threads at once. `Database` and `Statement` aren't `Sendable`, which makes the compiler
/// keep each connection, and the statements prepared on it, inside one thread or actor. Open a
/// connection per thread or actor that needs one; in WAL mode readers run alongside the writer.
public final class Database {
    /// How long a call waits for another connection's lock before failing with `SQLITE_BUSY`.
    static let busyTimeoutMs: Int32 = 5000

    let connection: OpaquePointer

    /// Opens or creates the file at `url` in WAL mode, with foreign keys enforced.
    public init(at url: URL) throws(SQLiteError) {
        connection = try Self.open(
            url, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX)
        // Switching a new file to WAL takes a lock SQLite doesn't wait for with the busy
        // timeout, so connections opening the same new file at once retry it within that time.
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(Self.busyTimeoutMs) * 1_000_000
        while true {
            do {
                try execute("PRAGMA journal_mode = WAL")
                break
            } catch let error
                where error.code & 0xFF == SQLITE_BUSY
                && DispatchTime.now().uptimeNanoseconds < deadline
            {
                usleep(1000)
            }
        }
        // synchronous=NORMAL is durable in WAL mode except across a power cut, which loses at
        // most the last transactions of a rescan.
        try execute("PRAGMA synchronous = NORMAL; PRAGMA foreign_keys = ON")
    }

    /// Opens the file at `url` read-only, for another program's database copied aside. Its
    /// schema can't call functions as it's read, since a hostile file can declare views and
    /// defaults that would (`trusted_schema`), and no statement on the connection can write.
    public init(readOnlyAt url: URL) throws(SQLiteError) {
        connection = try Self.open(url, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX)
        try execute("PRAGMA trusted_schema = OFF; PRAGMA query_only = ON")
    }

    private static func open(_ url: URL, _ flags: Int32) throws(SQLiteError) -> OpaquePointer {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(url.path, &connection, flags, nil) == SQLITE_OK, let connection
        else {
            let error = SQLiteError(connection, sql: nil)
            sqlite3_close_v2(connection)
            throw SQLiteError(code: error.code, message: "\(url.path): \(error.message)", sql: nil)
        }
        sqlite3_extended_result_codes(connection, 1)
        sqlite3_busy_timeout(connection, busyTimeoutMs)
        return connection
    }

    deinit {
        // Closes once the last statement is finalized, since statements may outlive this.
        sqlite3_close_v2(connection)
    }

    /// Runs one or more statements that take no parameters, discarding any rows.
    public func execute(_ sql: String) throws(SQLiteError) {
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteError(connection, sql: sql)
        }
    }

    public func prepare(_ sql: String) throws(SQLiteError) -> Statement {
        try Statement(self, sql)
    }

    /// Runs `body` in a transaction: committed when it returns, rolled back when it throws.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        let result = Result(catching: body)
        switch result {
        case .success: try execute("COMMIT")
        // SQLite rolls some failures back itself, such as SQLITE_FULL, and a second rollback
        // would fail and hide the error that caused it.
        case .failure: if isInTransaction { try execute("ROLLBACK") }
        }
        return try result.get()
    }

    /// Runs `body`'s reads in one deferred transaction, so they all see the same snapshot while
    /// other connections write. It takes no write lock.
    public func read<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN")
        let result = Result(catching: body)
        // Nothing was written, so ending it either way leaves nothing behind.
        if isInTransaction { try execute("COMMIT") }
        return try result.get()
    }

    /// What SQLite adds to a database's path for its write-ahead log and its shared-memory index.
    public static let walSuffix = "-wal"
    public static let shmSuffix = "-shm"

    /// The size of the database file at `url` plus its write-ahead log, which holds commits not
    /// yet checkpointed into the file.
    public static func sizeBytes(at url: URL) throws -> Int {
        try [url.path, url.path + walSuffix].reduce(0) { total, path in
            guard FileManager.default.fileExists(atPath: path) else { return total }
            guard let size = try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int
            else { throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: path]) }
            return total + size
        }
    }

    /// How many rows the last INSERT, UPDATE or DELETE on this connection changed.
    public var changes: Int { Int(sqlite3_changes(connection)) }

    /// Whether a transaction is open on this connection.
    public var isInTransaction: Bool { sqlite3_get_autocommit(connection) == 0 }

    /// The rowid of the last row inserted on this connection.
    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(connection) }
}
