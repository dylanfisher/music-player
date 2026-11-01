import SQLite3

/// SQLite copies bound text before the call returns. The C macro isn't imported into Swift.
private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A value a statement parameter can take. Nil binds NULL.
public protocol SQLiteValue {
    func bind(to statement: OpaquePointer, at index: Int32) -> Int32
}

extension Int: SQLiteValue {
    public func bind(to statement: OpaquePointer, at index: Int32) -> Int32 {
        sqlite3_bind_int64(statement, index, Int64(self))
    }
}

extension Int64: SQLiteValue {
    public func bind(to statement: OpaquePointer, at index: Int32) -> Int32 {
        sqlite3_bind_int64(statement, index, self)
    }
}

extension Double: SQLiteValue {
    public func bind(to statement: OpaquePointer, at index: Int32) -> Int32 {
        sqlite3_bind_double(statement, index, self)
    }
}

extension Bool: SQLiteValue {
    public func bind(to statement: OpaquePointer, at index: Int32) -> Int32 {
        sqlite3_bind_int64(statement, index, self ? 1 : 0)
    }
}

extension String: SQLiteValue {
    /// Bound by its byte count, so text holding a NUL, which a tag can, is bound whole. Text
    /// past what an Int32 counts is too big, as SQLite says of text past its own limit.
    public func bind(to statement: OpaquePointer, at index: Int32) -> Int32 {
        guard let count = Int32(exactly: utf8.count) else { return SQLITE_TOOBIG }
        return sqlite3_bind_text(statement, index, self, count, transient)
    }
}

/// A prepared statement. Prepare it once and run it many times; each run resets it and binds
/// its parameters afresh. Belongs to its `Database`'s thread or actor.
public final class Statement {
    private let database: Database
    private let statement: OpaquePointer
    let sql: String

    init(_ database: Database, _ sql: String) throws(SQLiteError) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database.connection, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { throw SQLiteError(database.connection, sql: sql) }
        self.database = database
        self.statement = statement
        self.sql = sql
    }

    deinit { sqlite3_finalize(statement) }

    /// Runs a statement that returns no rows.
    public func run(_ values: (any SQLiteValue)?...) throws(SQLiteError) {
        try run(binding: values)
    }

    /// `run` with the values as a list, for a statement with too many to list as arguments.
    public func run(binding values: [(any SQLiteValue)?]) throws(SQLiteError) {
        try start(values)
        defer { sqlite3_reset(statement) }
        while try step() {}
    }

    /// Runs a query, calling `body` for each row in order.
    public func query(_ values: (any SQLiteValue)?..., row body: (Row) throws -> Void) throws {
        try start(values)
        defer { sqlite3_reset(statement) }
        let row = Row(statement: statement, sql: sql)
        while try step() { try body(row) }
    }

    /// The rows of a query, each mapped by `transform`.
    public func map<T>(_ values: (any SQLiteValue)?..., row transform: (Row) throws -> T) throws
        -> [T]
    {
        try map(binding: values, row: transform)
    }

    /// `map` with the values as a list, for SQL whose parameter count varies.
    public func map<T>(binding values: [(any SQLiteValue)?], row transform: (Row) throws -> T)
        throws -> [T]
    {
        try start(values)
        defer { sqlite3_reset(statement) }
        let row = Row(statement: statement, sql: sql)
        var results: [T] = []
        while try step() { results.append(try transform(row)) }
        return results
    }

    private func start(_ values: [(any SQLiteValue)?]) throws(SQLiteError) {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        let expected = Int(sqlite3_bind_parameter_count(statement))
        guard values.count == expected else {
            throw SQLiteError(
                code: SQLITE_RANGE,
                message: "\(values.count) values for \(expected) parameters", sql: sql)
        }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result =
                value?.bind(to: statement, at: index) ?? sqlite3_bind_null(statement, index)
            if result == SQLITE_TOOBIG {
                throw SQLiteError(
                    code: result, message: "value \(index) is too big to bind", sql: sql)
            }
            guard result == SQLITE_OK else { throw SQLiteError(database.connection, sql: sql) }
        }
    }

    /// True when a row is ready, false when the statement is done.
    private func step() throws(SQLiteError) -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw SQLiteError(database.connection, sql: sql)
        }
    }
}

/// The current row of a running query. Only valid inside the `query` or `map` call that
/// produced it. Columns are numbered from 0, in the order the SELECT lists them.
public struct Row {
    let statement: OpaquePointer
    let sql: String

    func isNull(_ column: Int32) -> Bool {
        sqlite3_column_type(statement, column) == SQLITE_NULL
    }

    /// How SQLite stored the value, which a column of any declared type can vary row by row.
    public func storageClass(_ column: Int32) -> StorageClass {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER: .integer
        case SQLITE_FLOAT: .real
        case SQLITE_TEXT: .text
        case SQLITE_BLOB: .blob
        default: .null
        }
    }

    public func int(_ column: Int32) throws(SQLiteError) -> Int {
        try notNull(column)
        return Int(sqlite3_column_int64(statement, column))
    }

    public func optionalInt(_ column: Int32) -> Int? {
        isNull(column) ? nil : Int(sqlite3_column_int64(statement, column))
    }

    public func int64(_ column: Int32) throws(SQLiteError) -> Int64 {
        try notNull(column)
        return sqlite3_column_int64(statement, column)
    }

    public func double(_ column: Int32) throws(SQLiteError) -> Double {
        try notNull(column)
        return sqlite3_column_double(statement, column)
    }

    public func optionalDouble(_ column: Int32) -> Double? {
        isNull(column) ? nil : sqlite3_column_double(statement, column)
    }

    public func text(_ column: Int32) throws(SQLiteError) -> String {
        try notNull(column)
        // SQLite returns no text for a value that isn't NULL only when it runs out of memory.
        guard let text = optionalText(column) else {
            throw SQLiteError(code: SQLITE_NOMEM, message: "column \(column) has no text", sql: sql)
        }
        return text
    }

    /// Read by its byte count, so text holding a NUL comes back whole.
    public func optionalText(_ column: Int32) -> String? {
        // SQLite's docs ask for the text first, then its length.
        guard let text = sqlite3_column_text(statement, column) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        return String(decoding: UnsafeBufferPointer(start: text, count: count), as: UTF8.self)
    }

    /// A NULL where the caller expects a value means the schema and the query disagree.
    private func notNull(_ column: Int32) throws(SQLiteError) {
        guard !isNull(column) else {
            throw SQLiteError(
                code: SQLITE_MISMATCH, message: "column \(column) is NULL", sql: sql)
        }
    }
}

/// SQLite's storage classes.
public enum StorageClass: Sendable {
    case integer, real, text, blob, null
}
