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
    public static let busyTimeoutMs: Int32 = 5000

    let connection: OpaquePointer

    /// Opens or creates the file at `url` in WAL mode, with foreign keys enforced.
    public init(at url: URL) throws(SQLiteError) {
        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &connection, flags, nil) == SQLITE_OK, let connection
        else {
            let error = SQLiteError(connection, sql: nil)
            sqlite3_close_v2(connection)
            throw SQLiteError(code: error.code, message: "\(url.path): \(error.message)", sql: nil)
        }
        self.connection = connection
        sqlite3_extended_result_codes(connection, 1)
        sqlite3_busy_timeout(connection, Self.busyTimeoutMs)
        // synchronous=NORMAL is durable in WAL mode except across a power cut, which loses at
        // most the last transactions of a rescan.
        try execute(
            "PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA foreign_keys = ON")
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
        case .failure: try execute("ROLLBACK")
        }
        return try result.get()
    }

    /// The rowid of the last row inserted on this connection.
    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(connection) }
}
