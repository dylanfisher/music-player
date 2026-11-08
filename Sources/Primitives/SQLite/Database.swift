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
        // Reading pages through a mapping instead of a copy each, and sorting and grouping in
        // memory instead of a temporary file, measured faster on the library benchmarks
        // (ADR 0075).
        try execute(
            "PRAGMA mmap_size = \(Self.mappedBytes); PRAGMA temp_store = \(Self.memoryTempStore)")
        // SQLite lowers the size to its build's limit without an error.
        mappedBytesInEffect = try integer("PRAGMA mmap_size")
    }

    /// The integer in the first column of the first row `sql` gives.
    private func integer(_ sql: String) throws(SQLiteError) -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { throw SQLiteError(connection, sql: sql) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw SQLiteError(connection, sql: sql) }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// The most of the file a connection maps: several times a 43k-track library's.
    public static let mappedBytes = 256 << 20
    /// What this connection maps at most: `mappedBytes`, unless the SQLite build's limit is
    /// lower. Zero for a read-only connection, which maps nothing.
    public private(set) var mappedBytesInEffect = 0
    /// `temp_store`'s value for temporary tables and indexes in memory.
    static let memoryTempStore = 2

    /// Opens the file at `url` read-only, for another program's database copied aside. Its
    /// schema can't call functions as it's read, since a hostile file can declare views and
    /// defaults that would (`trusted_schema`), and no statement on the connection can write.
    public init(readOnlyAt url: URL) throws(SQLiteError) {
        connection = try Self.open(url, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX)
        try execute("PRAGMA trusted_schema = OFF; PRAGMA query_only = ON")
    }

    /// Opens the file at `url` with a rollback journal rather than WAL, for a file written in
    /// bulk in a few large transactions: WAL would write every page twice. A process killed
    /// mid-transaction leaves its journal, and the next connection to open the file rolls the
    /// transaction back. `creating` makes the file when there's none; otherwise a missing file
    /// fails. Foreign keys aren't enforced.
    public init(rollbackJournalAt url: URL, creating: Bool) throws(SQLiteError) {
        connection = try Self.open(
            url, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX | (creating ? SQLITE_OPEN_CREATE : 0))
        try execute("PRAGMA journal_mode = DELETE")
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

    /// Runs `body` in a deferred transaction, which takes no lock on the database file until
    /// `body` writes it: its reads see one snapshot while other connections write, and writes
    /// to temporary tables never wait for them. Committed when `body` returns, rolled back when
    /// it throws.
    public func deferredTransaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN DEFERRED")
        let result = Result(catching: body)
        switch result {
        case .success: try execute("COMMIT")
        case .failure: if isInTransaction { try execute("ROLLBACK") }
        }
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

    /// Asks the kernel to read the database file at `url` into its cache in the background, and
    /// returns at once. A launch's first queries read most of the file through the mapping, a
    /// page fault at a time, which from a cold cache is a random read per page; one sequential
    /// read ahead of them is several times faster on an old SSD (ADR 0086). A file that
    /// doesn't exist yet has nothing to read.
    public static func readAhead(at url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        // The advice's length is an Int32, so a file over 2 GB is read ahead only to there; a
        // 43k-track library is under 100 MB.
        var advice = radvisory(ra_offset: 0, ra_count: Int32(clamping: info.st_size))
        guard fcntl(descriptor, F_RDADVISE, &advice) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// How many rows the last INSERT, UPDATE or DELETE on this connection changed.
    public var changes: Int { Int(sqlite3_changes(connection)) }

    /// Whether a transaction is open on this connection.
    public var isInTransaction: Bool { sqlite3_get_autocommit(connection) == 0 }

    /// The rowid of the last row inserted on this connection.
    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(connection) }
}
