import SQLite3

/// A failed SQLite call: the result code, SQLite's message, and the SQL it was running.
public struct SQLiteError: Error, Equatable, CustomStringConvertible {
    /// The extended result code, such as `SQLITE_CONSTRAINT_UNIQUE`.
    public var code: Int32
    public var message: String
    /// Nil for calls that run no SQL, such as opening the file.
    public var sql: String?

    public var description: String {
        "SQLite error \(code): \(message)" + (sql.map { " in: \($0)" } ?? "")
    }
}

extension SQLiteError {
    /// The connection's last error, which describes the call that just failed.
    init(_ connection: OpaquePointer?, sql: String?) {
        code = sqlite3_extended_errcode(connection)
        message = String(cString: sqlite3_errmsg(connection))
        self.sql = sql
    }
}

extension SQLiteError {
    /// SQLITE_CONSTRAINT_FOREIGNKEY, which Swift doesn't import because it's an expression.
    /// A row refers to one that doesn't exist, such as an artist another connection deleted.
    public var isForeignKeyViolation: Bool { code == (SQLITE_CONSTRAINT | (3 << 8)) }
}

extension SQLiteError {
    /// SQLITE_NOTADB or SQLITE_CORRUPT: the file isn't a database SQLite can read, as opposed
    /// to one it can't reach right now, such as a locked or full one.
    public var isUnreadableFile: Bool { [SQLITE_NOTADB, SQLITE_CORRUPT].contains(code & 0xFF) }
}
