import Foundation
import SQLite3
import Testing

@testable import SQLite

/// A database file in a fresh temporary directory.
private func temporaryDatabase() throws -> Database {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("sqlite-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return try Database(at: directory.appendingPathComponent("test.sqlite"))
}

@Test func opensInWALModeWithForeignKeys() throws {
    let database = try temporaryDatabase()
    #expect(try database.prepare("PRAGMA journal_mode").map { try $0.text(0) } == ["wal"])
    #expect(try database.prepare("PRAGMA foreign_keys").map { try $0.int(0) } == [1])
}

@Test func bindsAndReadsEveryType() throws {
    let database = try temporaryDatabase()
    try database.execute("CREATE TABLE t (i INTEGER, r REAL, s TEXT, b INTEGER, n TEXT)")
    let insert = try database.prepare("INSERT INTO t VALUES (?, ?, ?, ?, ?)")
    try insert.run(7, 0.25, "Björk", true, nil)
    try insert.run(Int64.max, -1.5, "", false, "x")
    let rows = try database.prepare("SELECT i, r, s, b, n FROM t ORDER BY i").map { row in
        [
            "\(try row.int64(0))", "\(try row.double(1))", try row.text(2), "\(try row.int(3))",
            row.optionalText(4) ?? "nil",
        ]
    }
    #expect(rows == [["7", "0.25", "Björk", "1", "nil"], ["\(Int64.max)", "-1.5", "", "0", "x"]])
}

@Test func reusesAPreparedStatement() throws {
    let database = try temporaryDatabase()
    try database.execute("CREATE TABLE t (i INTEGER)")
    let insert = try database.prepare("INSERT INTO t VALUES (?)")
    for value in 0..<100 { try insert.run(value) }
    let select = try database.prepare("SELECT i FROM t WHERE i >= ? ORDER BY i")
    #expect(try select.map(98) { try $0.int(0) } == [98, 99])
    #expect(try select.map(99) { try $0.int(0) } == [99])
}

@Test func bindsAListOfValues() throws {
    let database = try temporaryDatabase()
    try database.execute("CREATE TABLE t (i INTEGER)")
    let insert = try database.prepare("INSERT INTO t VALUES (?)")
    for value in 0..<10 { try insert.run(value) }
    let values: [(any SQLiteValue)?] = [2, 5, 7]
    let query = try database.prepare("SELECT i FROM t WHERE i IN (?, ?, ?) ORDER BY i")
    #expect(try query.map(binding: values) { try $0.int(0) } == [2, 5, 7])
    #expect(throws: SQLiteError.self) { try query.map(binding: [1]) { try $0.int(0) } }
}

@Test func errorsCarryTheSQLAndMessage() throws {
    let database = try temporaryDatabase()
    let error = #expect(throws: SQLiteError.self) { try database.prepare("SELECT * FROM nope") }
    #expect(error?.sql == "SELECT * FROM nope")
    #expect(error?.message.contains("no such table: nope") == true)
    #expect(error?.code == SQLITE_ERROR)

    try database.execute("CREATE TABLE t (i INTEGER UNIQUE)")
    let insert = try database.prepare("INSERT INTO t VALUES (?)")
    try insert.run(1)
    let duplicate = #expect(throws: SQLiteError.self) { try insert.run(1) }
    // SQLITE_CONSTRAINT_UNIQUE, a macro Swift doesn't import.
    #expect(duplicate?.code == SQLITE_CONSTRAINT | 8 << 8)
    #expect(duplicate?.sql == "INSERT INTO t VALUES (?)")
}

@Test func rejectsTheWrongNumberOfValues() throws {
    let database = try temporaryDatabase()
    let statement = try database.prepare("SELECT ?, ?")
    let error = #expect(throws: SQLiteError.self) { try statement.run(1) }
    #expect(error?.code == SQLITE_RANGE)
}

@Test func readingNullAsAValueThrows() throws {
    let database = try temporaryDatabase()
    let error = #expect(throws: SQLiteError.self) {
        try database.prepare("SELECT NULL").map { try $0.text(0) }
    }
    #expect(error?.code == SQLITE_MISMATCH)
}

private struct Boom: Error {}

@Test func transactionCommitsOrRollsBack() throws {
    let database = try temporaryDatabase()
    try database.execute("CREATE TABLE t (i INTEGER)")
    let insert = try database.prepare("INSERT INTO t VALUES (?)")
    try database.transaction { try insert.run(1) }
    #expect(throws: Boom.self) {
        try database.transaction {
            try insert.run(2)
            throw Boom()
        }
    }
    #expect(try database.prepare("SELECT i FROM t").map { try $0.int(0) } == [1])
}

@Test func garbageFileFailsLoudly() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("sqlite-\(UUID().uuidString).sqlite")
    try Data(repeating: 0x41, count: 4096).write(to: url)
    let error = #expect(throws: SQLiteError.self) { try Database(at: url) }
    #expect(error?.code == SQLITE_NOTADB)
}

@Test func fts5IsAvailable() throws {
    let database = try temporaryDatabase()
    try database.execute("CREATE VIRTUAL TABLE search USING fts5(text)")
    try database.prepare("INSERT INTO search VALUES (?)").run("hello world")
    #expect(
        try database.prepare("SELECT rowid FROM search WHERE search MATCH ?").map("wor*") {
            try $0.int(0)
        } == [1])
}

@Test func sizeCountsTheWriteAheadLog() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("sqlite-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("size.sqlite")
    let database = try Database(at: url)
    try database.execute("CREATE TABLE t (b BLOB); INSERT INTO t VALUES (zeroblob(100000))")
    let walBytes = try #require(
        try FileManager.default.attributesOfItem(atPath: url.path + "-wal")[.size] as? Int)
    #expect(walBytes > 100_000)
    #expect(try Database.sizeBytes(at: url) > walBytes)
}

@Test func connectionsOpeningANewFileAtOnceAllSucceed() throws {
    for _ in 0..<40 {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sqlite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("race.sqlite")
        let failures = LockedFailures()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            do {
                _ = try Database(at: url)
            } catch {
                failures.add("\(error)")
            }
        }
        #expect(failures.all.isEmpty)
    }
}

private final class LockedFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [String] = []
    func add(_ failure: String) { lock.withLock { failures.append(failure) } }
    var all: [String] { lock.withLock { failures } }
}

@Test func readsAnOptionalDoubleAndCountsChanges() throws {
    let database = try temporaryDatabase()
    try database.execute("CREATE TABLE t (r REAL)")
    try database.execute("INSERT INTO t VALUES (2.5), (NULL), (1)")
    #expect(try database.prepare("SELECT r FROM t").map { $0.optionalDouble(0) } == [2.5, nil, 1])
    try database.execute("UPDATE t SET r = 0 WHERE r IS NOT NULL")
    #expect(database.changes == 2)
}

@Test func knowsWhetherATransactionIsOpen() throws {
    let database = try temporaryDatabase()
    #expect(!database.isInTransaction)
    try database.transaction { #expect(database.isInTransaction) }
    #expect(!database.isInTransaction)
}

@Test func aTransactionSQLiteRolledBackItselfThrowsWhatCausedIt() throws {
    let database = try temporaryDatabase()
    try database.execute("CREATE TABLE t (s TEXT)")
    let pages = try database.prepare("PRAGMA page_count").map { try $0.int(0) }[0]
    try database.execute("PRAGMA max_page_count = \(pages)")
    #expect {
        try database.transaction {
            try database.prepare("INSERT INTO t VALUES (?)").run(
                String(repeating: "x", count: 65_536))
        }
    } throws: { error in
        ((error as? SQLiteError)?.code ?? 0) & 0xFF == SQLITE_FULL
    }
    #expect(!database.isInTransaction)
    #expect(try database.prepare("SELECT count(*) FROM t").map { try $0.int(0) } == [0])
}

@Test func textWithNULRoundTripsWhole() throws {
    let database = try temporaryDatabase()
    try database.execute("CREATE TABLE t (s TEXT)")
    let insert = try database.prepare("INSERT INTO t VALUES (?)")
    for text in ["a\u{0}b", "\u{0}", "a\u{0}b%", "plain"] { try insert.run(text) }
    #expect(
        try database.prepare("SELECT s FROM t ORDER BY rowid").map { try $0.text(0) }
            == ["a\u{0}b", "\u{0}", "a\u{0}b%", "plain"])
    #expect(
        try database.prepare("SELECT length(CAST(s AS BLOB)) FROM t").map { try $0.int(0) } == [
            3, 1, 4, 5,
        ])
    #expect(
        try database.prepare("SELECT ?").map(binding: ["x\u{0}y"]) { $0.optionalText(0) }
            == ["x\u{0}y"])
}

@Test func aQuotedIdentifierStaysOneName() throws {
    let database = try temporaryDatabase()
    let name = "x\"; DROP TABLE keep; --"
    try database.execute("CREATE TABLE keep (a); CREATE TABLE \(quotedIdentifier(name)) (a)")
    try database.execute("DROP TABLE \(quotedIdentifier(name))")
    #expect(
        try database.prepare("SELECT name FROM sqlite_master WHERE type = 'table'").map {
            try $0.text(0)
        } == ["keep"])
}

@Test func textTooBigToBindThrowsSaying() throws {
    let database = try temporaryDatabase()
    // The same error the Int32 guard gives text past 2 GiB, at a size a test can afford.
    sqlite3_limit(database.connection, SQLITE_LIMIT_LENGTH, 100)
    let select = try database.prepare("SELECT ?")
    let error = #expect(throws: SQLiteError.self) {
        try select.map(binding: [String(repeating: "x", count: 200)]) { $0.optionalText(0) }
    }
    #expect(error?.code == SQLITE_TOOBIG)
    #expect(error?.message == "value 1 is too big to bind")
}

@Test func aReadOnlyCopyReadsItsLogAndRefusesWrites() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("sqlite-\(UUID().uuidString)")
    let copy = directory.appendingPathComponent("copy")
    try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("live.sqlite")
    let live = try Database(at: url)
    try live.execute("CREATE TABLE t (i INTEGER); INSERT INTO t VALUES (1), (2)")
    // The rows are still only in the log while the writer stays open; the copy has no -shm.
    for suffix in ["", Database.walSuffix] {
        try FileManager.default.copyItem(
            atPath: url.path + suffix, toPath: copy.path + "/live.sqlite" + suffix)
    }
    let database = try Database(readOnlyAt: copy.appendingPathComponent("live.sqlite"))
    #expect(try database.prepare("SELECT i FROM t ORDER BY i").map { try $0.int(0) } == [1, 2])
    let error = #expect(throws: SQLiteError.self) {
        try database.execute("INSERT INTO t VALUES (3)")
    }
    #expect(error.map { $0.code & 0xFF } == SQLITE_READONLY)
    #expect(try database.prepare("PRAGMA trusted_schema").map { try $0.int(0) } == [0])
}

@Test func eachValueReportsHowItWasStored() throws {
    let database = try temporaryDatabase()
    try database.execute(
        "CREATE TABLE t (v); INSERT INTO t VALUES (1), (1.5), ('a'), (x'00'), (NULL)")
    #expect(
        try database.prepare("SELECT v FROM t ORDER BY rowid").map { $0.storageClass(0) }
            == [.integer, .real, .text, .blob, .null])
}

@Test func aDeferredTransactionSeesOneSnapshotAndWaitsForNoWriter() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("sqlite-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("test.sqlite")
    let reader = try Database(at: url)
    let writer = try Database(at: url)
    try writer.execute("CREATE TABLE t (i INTEGER); INSERT INTO t VALUES (1)")
    let count = { try reader.prepare("SELECT count(*) FROM t").map { try $0.int(0) }[0] }
    let counts = try reader.deferredTransaction {
        let before = try count()
        try writer.execute("INSERT INTO t VALUES (2)")
        return [before, try count()]
    }
    #expect(counts == [1, 1])
    #expect(!reader.isInTransaction)
    #expect(try count() == 2)
    // A temporary table is written while another connection holds the write lock.
    try writer.execute("BEGIN IMMEDIATE")
    try reader.execute("CREATE TEMP TABLE scratch (i INTEGER)")
    try reader.deferredTransaction { try reader.execute("INSERT INTO scratch VALUES (1)") }
    try writer.execute("COMMIT")
    // A failure ends the transaction and is thrown.
    #expect(throws: SQLiteError.self) {
        try reader.deferredTransaction { try reader.execute("SELECT nope") }
    }
    #expect(!reader.isInTransaction)
}
