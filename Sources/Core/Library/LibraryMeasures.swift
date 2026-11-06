import Foundation
import Metadata
import SQLite

/// Joins the measures `m` made from file `f` as the index has it, so a file changed since its
/// analysis has none.
let currentMeasuresJoin = """
    \(measuresTable) m ON m.path = f.path AND m.size_bytes = f.size_bytes
        AND m.modified_seconds = f.modified_seconds
    """

/// The measures `m`'s columns `fileMeasures` reads, in its order.
private let measuresColumns = """
    m.format_id, m.sample_rate_hz, m.stored_bits, m.channels, m.is_float, m.duration_seconds,
    m.cutoff_hz, m.cutoff_steepness_db_per_khz, m.effective_bits, m.identical_channels,
    m.peak_dbfs, m.true_peak_dbtp, m.clipped_runs, m.dynamic_range
    """

/// The measures in `row`, selected as `measuresColumns` from column `first` on.
private func fileMeasures(_ row: Row, from first: Int32) throws -> FileMeasures {
    FileMeasures(
        formatID: try row.text(first), sampleRateHz: try row.double(first + 1),
        storedBits: row.optionalInt(first + 2), channels: try row.int(first + 3),
        isFloat: try row.int(first + 4) != 0, durationSeconds: try row.double(first + 5),
        cutoffHz: row.optionalDouble(first + 6),
        cutoffSteepnessDBPerKHz: row.optionalDouble(first + 7),
        effectiveBits: row.optionalInt(first + 8),
        identicalChannels: row.optionalInt(first + 9).map { $0 != 0 },
        peakDBFS: row.optionalDouble(first + 10), truePeakDBTP: row.optionalDouble(first + 11),
        clippedRuns: try row.int(first + 12), dynamicRange: row.optionalInt(first + 13))
}

extension LibraryIndex {
    /// The measures stored for `path`, when they were made from the file as `stamp` describes
    /// it; nil when there are none or the file has changed since.
    func measures(path: String, stamp: FileStamp) throws -> FileMeasures? {
        try statement(
            """
            SELECT \(measuresColumns) FROM \(measuresTable) m
            WHERE path = ? AND size_bytes = ? AND modified_seconds = ?
            """
        ).map(path, stamp.sizeBytes, stamp.modifiedSeconds) { try fileMeasures($0, from: 0) }
            .first
    }

    /// Each track's measures, made from its file as the index has it, in ID order.
    func measuredTracks() throws -> [(id: Int64, measures: FileMeasures)] {
        try statement(
            """
            SELECT t.file_id, \(measuresColumns) FROM tracks t
            JOIN files f ON f.id = t.file_id JOIN \(currentMeasuresJoin)
            ORDER BY t.file_id
            """
        ).map { row in (try row.int64(0), try fileMeasures(row, from: 1)) }
    }

    /// What Analyze Library has done of every track's file and what it has left. A file is done
    /// when it has measures made from it as the index has it, at or after the run's start, so
    /// a run again lists the files measured before it. DSD files are left out, as analysis
    /// refuses them.
    func analysisFiles() throws -> AnalysisFiles {
        let files = try statement(
            """
            SELECT f.path, f.size_bytes, f.modified_seconds,
                m.path IS NOT NULL AND ifnull(a.measured_seconds, 0)
                    >= ifnull((SELECT started_seconds FROM \(analysisRunTable)), 0),
                x.path IS NOT NULL
            FROM tracks t JOIN files f ON f.id = t.file_id
            LEFT JOIN \(currentMeasuresJoin)
            LEFT JOIN \(measuredAtTable) a ON a.path = m.path
            LEFT JOIN \(analysisFailuresTable) x ON x.path = f.path
                AND x.size_bytes = f.size_bytes AND x.modified_seconds = f.modified_seconds
            ORDER BY f.path
            """
        ).map { row in
            (
                path: try row.text(0),
                stamp: FileStamp(sizeBytes: try row.int(1), modifiedSeconds: try row.double(2)),
                done: try row.int(3) != 0, failed: try row.int(4) != 0
            )
        }.filter { !dsdFileExtensions.contains(($0.path as NSString).pathExtension.lowercased()) }
        let finished = try statement("SELECT finished FROM \(analysisRunTable)").map {
            try $0.int(0) != 0
        }
        let pending = files.filter { !$0.done }
        return AnalysisFiles(
            pending: pending.map { ($0.path, $0.stamp) }, done: files.count - pending.count,
            failed: pending.filter(\.failed).count, unfinished: finished == [false])
    }

    /// Starts a run of Analyze Library: `again` from now, so every file measured before counts
    /// as not done, and otherwise from where the last run started. Forgets the last run's
    /// failures, which the run tries again.
    func beginAnalysisRun(again: Bool, now: Date = Date()) throws {
        try database.transaction {
            if again {
                try statement(
                    """
                    INSERT OR REPLACE INTO \(analysisRunTable) (one, started_seconds, finished)
                    VALUES (1, ?, 0)
                    """
                ).run(now.timeIntervalSince1970)
            } else {
                try statement(
                    """
                    INSERT INTO \(analysisRunTable) (one, started_seconds, finished)
                    VALUES (1, 0, 0) ON CONFLICT (one) DO UPDATE SET finished = 0
                    """
                ).run()
            }
            try statement("DELETE FROM \(analysisFailuresTable)").run()
        }
    }

    /// The run went through every file it listed.
    func finishAnalysisRun() throws {
        try statement("UPDATE \(analysisRunTable) SET finished = 1").run()
    }

    /// The run couldn't analyze the file at `path` as `stamp` describes it, or store what it
    /// measured.
    func recordAnalysisFailure(path: String, stamp: FileStamp) throws {
        try statement(
            """
            INSERT OR REPLACE INTO \(analysisFailuresTable) (path, size_bytes, modified_seconds)
            VALUES (?, ?, ?)
            """
        ).run(path, stamp.sizeBytes, stamp.modifiedSeconds)
    }

    /// Keeps `measures` for `path` as `stamp` describes the file, replacing any row before, and
    /// notes when, `now`.
    func storeMeasures(
        _ measures: FileMeasures, path: String, stamp: FileStamp, now: Date = Date()
    ) throws {
        try database.transaction {
            try insertMeasures(measures, path: path, stamp: stamp)
            try statement(
                """
                INSERT OR REPLACE INTO \(measuredAtTable) (path, measured_seconds) VALUES (?, ?)
                """
            ).run(path, now.timeIntervalSince1970)
        }
    }

    private func insertMeasures(_ measures: FileMeasures, path: String, stamp: FileStamp) throws {
        try statement(
            """
            INSERT OR REPLACE INTO \(measuresTable) (
                path, size_bytes, modified_seconds, format_id, sample_rate_hz, stored_bits,
                channels, is_float, duration_seconds, cutoff_hz, cutoff_steepness_db_per_khz,
                effective_bits, identical_channels, peak_dbfs, true_peak_dbtp, clipped_runs,
                dynamic_range)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        ).run(
            path, stamp.sizeBytes, stamp.modifiedSeconds, measures.formatID,
            measures.sampleRateHz, measures.storedBits, measures.channels, measures.isFloat,
            measures.durationSeconds, measures.cutoffHz, measures.cutoffSteepnessDBPerKHz,
            measures.effectiveBits, measures.identicalChannels, measures.peakDBFS,
            measures.truePeakDBTP, measures.clippedRuns, measures.dynamicRange)
    }
}
