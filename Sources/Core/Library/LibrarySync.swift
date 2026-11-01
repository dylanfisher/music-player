import DisplayText
import Foundation
import Log
import SQLite

private let logger = moduleLogger()

/// Syncing with the sync folder (ADR 0038): this machine's log goes out, the others' come in.
extension LibraryIndex {
    /// How many events one transaction applies, with how far it read each log: enough that
    /// commits and checkpoints don't dominate a long log, few enough that an edit in the window
    /// waits a fraction of a second.
    static let syncBatch = 20_000

    /// Pushes this machine's log to the folder at `path`, which is named `folder` in the
    /// config, then reads and applies every other machine's log there. Only the push runs when
    /// `pushOnly`. A problem with one log is in the report, and the others carry on; a folder
    /// that can't be opened, or this machine's log there not matching, throws.
    public func sync(folder: String, at path: String, pushOnly: Bool = false) throws -> SyncReport {
        let directory = try SyncDirectory(path: path)
        var report = SyncReport()
        report.pushed = try push(to: directory, folder: folder)
        if !pushOnly { try merge(from: directory, folder: folder, into: &report) }
        return report
    }

    // MARK: Pushing

    /// Appends what the folder's copy of this machine's log lacks, which is always a byte
    /// prefix of the outbox, and returns how many events went.
    private func push(to directory: SyncDirectory, folder: String) throws -> Int {
        let state = try statement(
            "SELECT machine, pushed_folder, pushed_seq, pushed_bytes FROM \(syncStateTable)"
        ).map { row in
            (
                machine: try row.text(0), folder: row.optionalText(1), seq: try row.int64(2),
                bytes: try row.int(3)
            )
        }[0]
        let same = state.folder == folder
        var seq = same ? state.seq : 0
        var bytes = same ? state.bytes : 0
        let last = try statement("SELECT ifnull(max(seq), 0) FROM \(syncOutboxTable)").map {
            try $0.int64(0)
        }[0]
        // Nothing waiting means no call to the folder at all.
        guard last > seq || !same else { return 0 }
        let file = try directory.openForAppending(syncLogName(state.machine))
        guard file.size >= bytes else {
            throw SyncFileError.notOurs(
                file.name, "it's \(file.size) bytes, and \(bytes) were written to it")
        }
        // Bytes past what was recorded: a push that stopped before recording them.
        var unrecorded = file.size - bytes
        var written = 0
        var pending: [UInt8] = []
        let record = try statement(
            "UPDATE \(syncStateTable) SET pushed_folder = ?, pushed_seq = ?, pushed_bytes = ?")
        func flush() throws {
            if !pending.isEmpty { try file.append(pending) }
            pending = []
            try record.run(folder, seq, bytes)
        }
        let rows = try statement(
            "SELECT seq, line FROM \(syncOutboxTable) WHERE seq > ? ORDER BY seq LIMIT 1000")
        while true {
            let lines = try rows.map(seq) { (try $0.int64(0), try $0.text(1)) }
            guard !lines.isEmpty else { break }
            for (number, line) in lines {
                let data = Array(line.utf8) + [0x0A]
                var start = 0
                if unrecorded > 0 {
                    start = min(unrecorded, data.count)
                    guard try file.read(bytes..<(bytes + start)) == Array(data[..<start]) else {
                        throw SyncFileError.notOurs(file.name, "its bytes from \(bytes) differ")
                    }
                    unrecorded -= start
                }
                pending += data[start...]
                seq = number
                bytes += data.count
                written += 1
                if pending.count >= SyncLogLines.chunkBytes { try flush() }
            }
        }
        guard unrecorded == 0 else {
            throw SyncFileError.notOurs(file.name, "it has \(unrecorded) bytes past this Mac's log")
        }
        try flush()
        if written > 0 { logger.info("pushed \(written) events to \(directory.path)") }
        return written
    }

    // MARK: Merging

    /// Reads every other machine's log in clock order, applying a batch of events at a time
    /// with how far each log was read, so a crash repeats nothing.
    private func merge(from directory: SyncDirectory, folder: String, into report: inout SyncReport)
        throws
    {
        let me = syncLogName(try machineID())
        var names = try directory.logNames().filter { $0 != me }
        if names.count > SyncDirectory.maximumLogs {
            report.problems.append(
                "\(directory.path): \(names.count) logs, of which the first"
                    + " \(SyncDirectory.maximumLogs) are read")
            names = Array(names.prefix(SyncDirectory.maximumLogs))
        }
        let read = try statement(
            "SELECT folder, offset, seq, lines FROM \(syncLogsTable) WHERE machine = ?")
        var cursors: [SyncCursor] = []
        for name in names {
            let machine = SyncDirectory.machine(ofLog: name)!
            let stored = try read.map(machine) {
                (
                    folder: try $0.text(0), offset: try $0.int(1), seq: try $0.int64(2),
                    lines: try $0.int(3)
                )
            }.first
            do {
                let file = try directory.openForReading(name)
                var cursor = SyncCursor(machine: machine, file: file)
                if let stored {
                    cursor.seq = stored.seq
                    cursor.quietThrough = stored.seq
                    if stored.folder == folder, stored.offset <= file.size {
                        cursor.restart(at: stored.offset, lines: stored.lines)
                    } else if stored.folder == folder {
                        cursor.note(
                            "it's \(file.size) bytes, shorter than the \(stored.offset) read"
                                + " before, so it's read again from the start")
                    }
                }
                try cursor.advance(wallMs: wallClockMs())
                cursors.append(cursor)
            } catch let error as SyncFileError {
                report.problems.append("\(error)")
            }
        }
        var merge = SyncMerge(roots: try syncRoots())
        let save = try statement(
            "INSERT OR REPLACE INTO \(syncLogsTable) (machine, folder, offset, seq, lines)"
                + " VALUES (?, ?, ?, ?, ?)")
        while cursors.contains(where: { $0.head != nil }) {
            try database.transaction {
                var applied = 0
                while applied < Self.syncBatch,
                    let next = cursors.indices.filter({ cursors[$0].head != nil }).min(by: {
                        cursors[$0].order < cursors[$1].order
                    })
                {
                    let record = cursors[next].head!
                    if let problem = try apply(record, from: cursors[next].machine, &merge) {
                        cursors[next].note("event \(record.seq): \(problem)")
                    }
                    try cursors[next].applied(wallMs: wallClockMs())
                    applied += 1
                }
                report.applied += applied
                for cursor in cursors {
                    try save.run(cursor.machine, folder, cursor.offset, cursor.seq, cursor.lines)
                }
            }
        }
        // A log with only skipped lines still records how far it was read.
        try database.transaction {
            for cursor in cursors {
                try save.run(cursor.machine, folder, cursor.offset, cursor.seq, cursor.lines)
            }
        }
        report.outside += merge.outside
        report.changed = report.changed || merge.changed
        for cursor in cursors { report.problems += cursor.reportLines(in: directory.path) }
    }
}

/// One other machine's log as a sync reads it: its next event, and how far it was applied.
private struct SyncCursor {
    let machine: String
    let file: SyncLogFile
    /// Applied up to here, and that many lines.
    private(set) var offset = 0
    private(set) var lines = 0
    /// The last sequence number applied.
    var seq: Int64 = 0
    /// The next event, decoded but not yet applied.
    private(set) var head: SyncRecord?
    private var reader: SyncLogLines
    private var lastDecoded: Int64 = 0
    private var problems: [String] = []
    private var unlisted = 0
    private var reportedAhead = false
    private var reportedCap = false

    init(machine: String, file: SyncLogFile) {
        self.machine = machine
        self.file = file
        reader = Self.reader(file, from: 0)
    }

    private static func reader(_ file: SyncLogFile, from offset: Int) -> SyncLogLines {
        SyncLogLines(from: offset, end: min(file.size, SyncRecord.maximumLogBytes)) {
            [file] range in try file.read(range)
        }
    }

    /// The merge's order: by clock, then by machine.
    var order: SyncStamp {
        SyncStamp(clock: head!.clock, machine: machine)
    }

    /// Read from the start again, events up to here were applied before.
    var quietThrough: Int64 = 0

    mutating func restart(at offset: Int, lines: Int) {
        quietThrough = 0
        self.offset = offset
        self.lines = lines
        reader = Self.reader(file, from: offset)
    }

    mutating func note(_ problem: String) {
        if problems.count < SyncReport.maximumProblems {
            problems.append(problem)
        } else {
            unlisted += 1
        }
    }

    /// The head was applied: the log is applied past it, and the next event becomes the head.
    mutating func applied(wallMs: Int64) throws {
        if let head { seq = head.seq }
        offset = reader.offset
        lines += 1
        try advance(wallMs: wallMs)
    }

    /// Reads to the next event that decodes, noting each line that doesn't, up to the caps.
    mutating func advance(wallMs: Int64) throws {
        head = nil
        if file.size > SyncRecord.maximumLogBytes, !reportedCap {
            reportedCap = true
            note("it's \(file.size) bytes; only the first \(SyncRecord.maximumLogBytes) are read")
        }
        while lines < SyncRecord.maximumEvents, let line = try reader.next() {
            let number = lines + 1
            switch line {
            case .tooLong(let bytes):
                note("line \(number) is \(bytes) bytes, over \(SyncRecord.maximumLineBytes)")
            case .line(let bytes):
                do throws(SyncLineProblem) {
                    let record = try SyncRecord(line: bytes[...])
                    // One applied before, read again from the start.
                    if record.seq <= quietThrough { break }
                    let previous = max(seq, lastDecoded)
                    guard record.seq > previous else {
                        note("line \(number): event \(record.seq) comes after \(previous)")
                        break
                    }
                    lastDecoded = record.seq
                    if record.clock.ms > wallMs + SyncClock.skewBoundMs, !reportedAhead {
                        reportedAhead = true
                        note(
                            "its clock is \((record.clock.ms - wallMs) / 1000) seconds ahead of"
                                + " this Mac's; its edits win until the clocks agree")
                    }
                    head = record
                    return
                } catch {
                    note("line \(number) \(error)")
                }
            }
            // A skipped line counts as read.
            lines = number
            offset = reader.offset
        }
        if lines >= SyncRecord.maximumEvents, !reportedCap {
            reportedCap = true
            note("it has \(SyncRecord.maximumEvents) events, past which nothing is read")
        }
    }

    /// The problems, each on a line naming the log, and a count of those not listed. A log's
    /// text in them is escaped, so a line break can't fake a row of the report.
    func reportLines(in folder: String) -> [String] {
        let name = folder + "/" + file.name
        return problems.map { terminalSafe("\(name): \($0)") }
            + (unlisted > 0 ? ["\(name): \(unlisted) more problems"] : [])
    }
}
