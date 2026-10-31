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
