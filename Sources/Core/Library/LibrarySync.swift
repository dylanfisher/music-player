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
    /// How many syncs an event waits for its playlist's create before it's skipped.
    static let maximumWaitingSyncs = 10

    /// Pushes this machine's log to the folder at `path`, which is named `folder` in the
    /// config, then reads and applies every other machine's log there. Only the push runs when
    /// `pushOnly`. A problem with one log is in the report, and the others carry on; a folder
    /// that can't be opened throws. A push that can't go, such as to a log some other process
    /// wrote, is in the report, and the others' logs are still read.
    public func sync(folder: String, at path: String, pushOnly: Bool = false) throws -> SyncReport {
        let directory = try SyncDirectory(path: path)
        var report = SyncReport()
        do {
            report.pushed = try push(to: directory, folder: folder)
        } catch let error as SyncFileError {
            logger.error("\(error)")
            report.problems.append("\(error)")
        }
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
        // One push at a time, should a second copy of the app open this library.
        let lock = open(fileURL.path + ".sync-lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard lock >= 0 else { throw SyncFileError.open(fileURL.path + ".sync-lock", errno) }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            throw SyncFileError.refused(
                fileURL.path + ".sync-lock", "is held by another copy of the app, which pushes")
        }
        let file = try directory.openForAppending(syncLogName(state.machine))
        // An empty log is one the owner moved away to start it again: it gets the whole log.
        if file.size == 0 {
            seq = 0
            bytes = 0
        }
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
            "SELECT folder, offset, seq, lines, waiting_seq, waiting_syncs FROM \(syncLogsTable)"
                + " WHERE machine = ?")
        var cursors: [SyncCursor] = []
        for name in names {
            let machine = SyncDirectory.machine(ofLog: name)!
            let stored = try read.map(machine) {
                (
                    folder: try $0.text(0), offset: try $0.int(1), seq: try $0.int64(2),
                    lines: try $0.int(3), waiting: (seq: try $0.int64(4), syncs: try $0.int(5))
                )
            }.first
            do {
                let file = try directory.openForReading(name)
                var cursor = SyncCursor(machine: machine, file: file)
                if let stored {
                    cursor.seq = stored.seq
                    cursor.quietThrough = stored.seq
                    cursor.storedWaiting = stored.waiting
                    // Where reading stopped must still end a line, or the log was replaced.
                    let endsLine =
                        try stored.offset <= file.size
                        && (stored.offset == 0
                            || file.read((stored.offset - 1)..<stored.offset) == [0x0A])
                    if stored.folder == folder, endsLine {
                        cursor.restart(at: stored.offset, lines: stored.lines)
                    } else if stored.folder == folder {
                        cursor.note(
                            "it's no longer what was read before (\(file.size) bytes, read to"
                                + " \(stored.offset)), so it's read again from the start")
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
            "INSERT OR REPLACE INTO \(syncLogsTable) (machine, folder, offset, seq, lines,"
                + " waiting_seq, waiting_syncs) VALUES (?, ?, ?, ?, ?, ?, ?)")
        func saveAll(endingPass: Bool) throws {
            for cursor in cursors {
                let waiting = endingPass ? cursor.waitingAtEnd : cursor.storedWaiting
                try save.run(
                    cursor.machine, folder, cursor.offset, cursor.seq, cursor.lines, waiting.seq,
                    waiting.syncs)
            }
        }
        // Events applied this pass; a log waiting for a playlist's create is read again once
        // another event was applied, which may have been the create.
        var total = 0
        var stopped = false
        func eligible(_ cursor: SyncCursor) -> Bool {
            cursor.head != nil && (cursor.waitingSince.map { $0 < total } ?? true)
        }
        while !stopped, cursors.contains(where: eligible) {
            try database.transaction {
                var work = 0
                while work < Self.syncBatch,
                    let next = cursors.indices.filter({ eligible(cursors[$0]) }).min(by: {
                        cursors[$0].order < cursors[$1].order
                    })
                {
                    guard merge.newPaths < maximumNewPathsPerSync else {
                        report.problems.append(
                            "this sync added \(merge.newPaths) paths, the most one does; the"
                                + " rest of the logs wait for the next")
                        stopped = true
                        break
                    }
                    let record = cursors[next].head!
                    do {
                        if let problem = try apply(record, from: cursors[next].machine, &merge) {
                            cursors[next].note("event \(record.seq): \(problem)")
                        }
                    } catch let waiting as SyncWaitsForCreate {
                        guard cursors[next].givesUpWaiting else {
                            cursors[next].waitingSince = total
                            continue
                        }
                        cursors[next].note(
                            "event \(record.seq): it changes the playlist \(waiting.playlist),"
                                + " which no log created in \(Self.maximumWaitingSyncs) syncs")
                    }
                    do {
                        try cursors[next].applied(wallMs: wallClockMs())
                    } catch let error as SyncFileError {
                        // Read no more of that log this pass; the rest waits for the next.
                        cursors[next].note("\(error)")
                    }
                    total += 1
                    work += record.event.work
                }
                try saveAll(endingPass: false)
            }
        }
        report.applied = total
        // A log with only skipped lines still records how far it was read, and one waiting
        // counts the syncs it has waited.
        try database.transaction { try saveAll(endingPass: true) }
        if merge.outside > 0 {
            report.problems.append(
                "events for files outside this Mac's share folders, which it doesn't keep:"
                    + " \(merge.outside)")
        }
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
    /// The event that waited for its playlist's create at the end of the last syncs, and how
    /// many of them.
    var storedWaiting: (seq: Int64, syncs: Int) = (0, 0)
    /// How many events the pass had applied when the head started waiting for its create.
    var waitingSince: Int?

    /// Whether the head has waited for its playlist's create as long as it may.
    var givesUpWaiting: Bool {
        storedWaiting.seq == head?.seq && storedWaiting.syncs >= LibraryIndex.maximumWaitingSyncs
    }

    /// What to store of the head's wait as the pass ends.
    var waitingAtEnd: (seq: Int64, syncs: Int) {
        guard waitingSince != nil, let head else { return (0, 0) }
        return (head.seq, storedWaiting.seq == head.seq ? storedWaiting.syncs + 1 : 1)
    }

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
        waitingSince = nil
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
