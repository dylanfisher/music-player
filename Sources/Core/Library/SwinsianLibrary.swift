import Darwin
import Foundation
import Log
import Metadata
import SQLite
import Settings

private let logger = moduleLogger()

/// Reads a Swinsian library database (ADR 0033). The schema is assumed, not known: every table
/// and column read is checked first, and one missing fails the read naming each.
extension PlayerLibrary {
    /// The database and its write-ahead log together; the owner's 43k tracks take about 100 MB.
    static let maximumDatabaseBytes = 4 << 30

    /// Copies the database at `url` and its log aside, reads the copy, and deletes it. The file
    /// itself is only read through `FileSource`, never opened by SQLite.
    init(swinsianAt url: URL, now: Double = Date().timeIntervalSince1970) throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("swinsian-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer {
            do {
                try FileManager.default.removeItem(at: folder)
            } catch {
                logger.error("couldn't delete the copy of the Swinsian library: \(error)")
            }
        }
        let copy = folder.appendingPathComponent("copy.sqlite")
        try copyAside(url.path, to: copy.path)
        try self.init(swinsianCopy: copy, source: url.path, now: now)
    }

    /// Reads a database already copied aside, which SQLite may write a `-shm` beside.
    init(swinsianCopy copy: URL, source: String, now: Double) throws {
        self.init(player: .swinsian, source: source)
        let database: Database
        do {
            database = try Database(readOnlyAt: copy)
            try checkSchema(database)
        } catch let error as SQLiteError {
            throw PlayerImportError.unreadable(error.message)
        }
        let ids = try readTracks(database, now: now)
        try readPlaylists(database, tracks: ids)
    }

    private mutating func readTracks(_ database: Database, now: Double) throws -> [Int64: String] {
        let columns = trackTable.columns
        var paths: [Int64: String] = [:]
        try database.prepare(trackTable.select(orderedBy: [0]) + " LIMIT ?").query(
            Self.maximumTracks + 1
        ) { row in
            guard paths.count < Self.maximumTracks else {
                note(PlayerLibraryProblem(trackTable.name, .tooMany(.tracks)))
                return
            }
            guard case .integer(let id) = Cell(row, 0) else {
                note(
                    PlayerLibraryProblem(
                        trackTable.name, .wrongType(columns[0], expected: Int.typeName)))
                return
            }
            let item = PlayerLibraryProblem.track(id)
            guard case .text(let written) = Cell(row, 1) else {
                let kind: PlayerLibraryProblem.Kind =
                    Cell(row, 1) == .null
                    ? .noPath : .wrongType(columns[1], expected: String.typeName)
                note(PlayerLibraryProblem(item, kind))
                return
            }
            guard let path = checkedText(written, item, maximumBytes: Self.maximumPathBytes)
            else { return }
            guard path.hasPrefix("/") else {
                note(PlayerLibraryProblem(item, .notAbsolute))
                return
            }
            var track = PlayerTrack(path: path)
            track.plays = count(Cell(row, 2), item, columns[2]) ?? 0
            track.lastPlayedSeconds = date(Cell(row, 3), item, columns[3], now: now)
            track.addedSeconds = date(Cell(row, 4), item, columns[4], now: now)
            track.rating = stars(Cell(row, 5), item, columns[5])
            track.loved = flag(Cell(row, 6), item, columns[6])
            paths[id] = add(track)
        }
        return paths
    }

    private mutating func readPlaylists(_ database: Database, tracks: [Int64: String]) throws {
        var entries: [Int64: [Cell]] = [:]
        var entryCount = 0
        // By playlist, then position.
        try database.prepare(entryTable.select(orderedBy: [0, 2]) + " LIMIT ?").query(
            Self.maximumEntries + 1
        ) { row in
            guard entryCount < Self.maximumEntries else {
                note(PlayerLibraryProblem(entryTable.name, .tooMany(.entries)))
                return
            }
            entryCount += 1
            guard case .integer(let playlist) = Cell(row, 0) else { return }
            entries[playlist, default: []].append(Cell(row, 1))
        }
        var rules: [Int64: [SwinsianRule]] = [:]
        try database.prepare(ruleTable.select(orderedBy: [0, 1])).query { row in
            guard case .integer(let playlist) = Cell(row, 0) else { return }
            rules[playlist, default: []].append(
                SwinsianRule(field: Cell(row, 2), operator: Cell(row, 3), value: Cell(row, 4)))
        }
        let columns = playlistTable.columns
        var playlistCount = 0
        try database.prepare(playlistTable.select(orderedBy: [0]) + " LIMIT ?").query(
            Self.maximumPlaylists + 1
        ) { row in
            guard playlistCount < Self.maximumPlaylists else {
                note(PlayerLibraryProblem(playlistTable.name, .tooMany(.playlists)))
                return
            }
            playlistCount += 1
            guard case .integer(let id) = Cell(row, 0) else {
                note(
                    PlayerLibraryProblem(
                        playlistTable.name, .wrongType(columns[0], expected: Int.typeName)))
                return
            }
            let numbered = PlayerLibraryProblem.playlist(id)
            guard case .text(let written) = Cell(row, 1) else {
                note(
                    PlayerLibraryProblem(
                        numbered, .wrongType(columns[1], expected: String.typeName)))
                return
            }
            guard let name = checkedText(written, numbered, maximumBytes: Self.maximumNameBytes)
            else { return }
            let item = PlayerLibraryProblem.playlist(named: name)
            var playlist = PlayerPlaylist(name: name, kind: .manual)
            if flag(Cell(row, 2), item, columns[2]) {
                let matchAll = flag(Cell(row, 3), item, columns[3])
                playlist.kind = swinsianKind(rules[id] ?? [], matchAll: matchAll)
            } else {
                for entry in entries[id] ?? [] {
                    guard case .integer(let track) = entry else {
                        note(
                            PlayerLibraryProblem(
                                item, .wrongType(entryTable.columns[1], expected: Int.typeName)))
                        continue
                    }
                    guard let path = tracks[track] else {
                        note(PlayerLibraryProblem(item, .unknownTrack(track)))
                        continue
                    }
                    playlist.paths.append(path)
                }
            }
            playlists.append(playlist)
        }
    }

    /// A count of 0 or more, or nil after noting why not; NULL is 0.
    private mutating func count(_ cell: Cell, _ item: String, _ column: String) -> Int? {
        switch cell {
        case .null: return 0
        case .integer(let value) where value >= 0 && value <= Int32.max: return Int(value)
        case .integer(let value):
            note(PlayerLibraryProblem(item, .outOfRange(column, "\(value)")))
        default: note(PlayerLibraryProblem(item, .wrongType(column, expected: Int.typeName)))
        }
        return nil
    }

    /// Seconds since 1970 from Swinsian's seconds since 2001, or nil for NULL or after noting
    /// why not.
    private mutating func date(_ cell: Cell, _ item: String, _ column: String, now: Double)
        -> Double?
    {
        let seconds: Double
        switch cell {
        case .null: return nil
        case .integer(let value): seconds = Double(value)
        case .real(let value): seconds = value
        default:
            note(PlayerLibraryProblem(item, .wrongType(column, expected: Double.typeName)))
            return nil
        }
        return checkedDate(
            seconds + Date.timeIntervalBetween1970AndReferenceDate, item, column, now: now)
    }

    private mutating func stars(_ cell: Cell, _ item: String, _ column: String) -> Int? {
        guard let stars = count(cell, item, column) else { return nil }
        guard stars <= SmartField.maxRating else {
            note(PlayerLibraryProblem(item, .outOfRange(column, "\(stars)")))
            return nil
        }
        return stars == 0 ? nil : stars
    }

    private mutating func flag(_ cell: Cell, _ item: String, _ column: String) -> Bool {
        switch cell {
        case .null: return false
        case .integer(let value) where value == 0 || value == 1: return value == 1
        default:
            note(PlayerLibraryProblem(item, .wrongType(column, expected: Bool.typeName)))
            return false
        }
    }

    private func swinsianKind(_ rules: [SwinsianRule], matchAll: Bool) -> PlayerPlaylist.Kind {
        guard rules.count <= Self.maximumRules else {
            return .unmapped(["more than \(Self.maximumRules) rules"])
        }
        var mapped: [SmartRule] = []
        var unmapped: [String] = []
        for rule in rules {
            switch rule.smartRule() {
            case .success(let rule): mapped.append(rule)
            case .failure(let reason): unmapped.append(reason.description)
            }
        }
        return unmapped.isEmpty
            ? .smart(SmartRules(match: matchAll ? .all : .any, rules: mapped)) : .unmapped(unmapped)
    }
}

/// A table the reader uses, and the columns it reads, in the order it reads them.
struct SwinsianTable: Sendable {
    var name: String
    var columns: [String]

    /// Selects every column, ordered by the columns at `order`. Only names from
    /// `swinsianSchema` are spliced in.
    func select(orderedBy order: [Int]) -> String {
        "SELECT \(columns.joined(separator: ", ")) FROM \(name) ORDER BY "
            + order.map { columns[$0] }.joined(separator: ", ")
    }
}

/// The schema ADR 0033 assumes, unverified: a table on each line, then its columns.
let swinsianSchema = """
    track track_id path playcount lastplayed dateadded rating loved
    playlist playlist_id name smart matchall
    playlisttrack playlist_id track_id position
    smartrule playlist_id position field operator value
    """.split(separator: "\n").map { line in
        let words = line.split(separator: " ").map(String.init)
        return SwinsianTable(name: words[0], columns: Array(words.dropFirst()))
    }

private let trackTable = swinsianSchema[0]
private let playlistTable = swinsianSchema[1]
private let entryTable = swinsianSchema[2]
private let ruleTable = swinsianSchema[3]

/// Throws `missingSchema` naming each table and column of `swinsianSchema` the database
/// doesn't have. Names compare ignoring ASCII case, as SQLite's do.
private func checkSchema(_ database: Database) throws {
    let tables = Set(
        try database.prepare(tableNamesSQL).map { try $0.text(0).lowercased() })
    var missing: [String] = []
    for table in swinsianSchema {
        guard tables.contains(table.name) else {
            missing.append("table \(table.name)")
            continue
        }
        let present = Set(
            try database.prepare("SELECT name FROM pragma_table_info(?)").map(table.name) {
                try $0.text(0).lowercased()
            })
        missing += table.columns.filter { !present.contains($0) }.map {
            "column \(table.name).\($0)"
        }
    }
    if !missing.isEmpty { throw PlayerImportError.missingSchema(missing) }
}

/// A value of a Swinsian row, as SQLite stored it, since a column of any declared type can
/// hold any type.
enum Cell: Equatable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob

    init(_ row: Row, _ column: Int32) {
        switch row.storageClass(column) {
        case .integer: self = .integer(row.optionalInt(column).map(Int64.init) ?? 0)
        case .real: self = .real(row.optionalDouble(column) ?? 0)
        case .text: self = .text(row.optionalText(column) ?? "")
        case .null: self = .null
        case .blob: self = .blob
        }
    }
}

/// Copies the file at `path` and its write-ahead log, if it has one, to `copy` through
/// `FileSource`, and throws if either changed while it was read.
private func copyAside(_ path: String, to copy: String) throws {
    let log = path + Database.walSuffix
    let before = (identity(path), identity(log))
    guard before.0 != nil else {
        throw PlayerImportError.unreadable("\(path): \(String(cString: strerror(errno)))")
    }
    var total = 0
    for (from, to) in [(path, copy), (log, copy + Database.walSuffix)] {
        if from == log && before.1 == nil { continue }
        total += try copyFile(from, to: to, budget: PlayerLibrary.maximumDatabaseBytes - total)
    }
    guard identity(path) == before.0 else { throw PlayerImportError.changedWhileCopying(path) }
    guard identity(log) == before.1 else { throw PlayerImportError.changedWhileCopying(log) }
}

/// Size, modification time and inode from `lstat`, or nil when there's nothing at `path`.
private func identity(_ path: String) -> [Int]? {
    var info = stat()
    guard lstat(path, &info) == 0 else { return nil }
    return [
        Int(info.st_size), info.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec, Int(info.st_ino),
    ]
}

/// Copies `from` to a new file at `to` a megabyte at a time and returns its size, refusing a
/// file over `budget` before reading it.
private func copyFile(_ from: String, to: String, budget: Int) throws -> Int {
    let source: FileSource
    do throws(ParseFailure) {
        source = try FileSource(path: from, hints: .all)
    } catch {
        throw PlayerImportError.unreadable("\(from): \(error.detail)")
    }
    guard source.size <= budget else {
        throw PlayerImportError.tooLarge(source.size, maximum: PlayerLibrary.maximumDatabaseBytes)
    }
    guard FileManager.default.createFile(atPath: to, contents: nil),
        let output = FileHandle(forWritingAtPath: to)
    else { throw PlayerImportError.unreadable("couldn't make the copy at \(to)") }
    let chunk = 1 << 20
    var offset = 0
    while offset < source.size {
        let end = min(source.size, offset + chunk)
        let bytes: [UInt8]
        do throws(ParseFailure) {
            bytes = try source.read(offset..<end)
        } catch {
            throw PlayerImportError.unreadable("\(from): \(error.detail)")
        }
        try output.write(contentsOf: Data(bytes))
        offset = end
    }
    try output.close()
    return source.size
}
