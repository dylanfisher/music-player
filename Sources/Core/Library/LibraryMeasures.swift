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

    /// Every track's file with no measures made from it as the index has it, with that stamp,
    /// in path order, so a pass over a share reads a folder at a time. DSD files are left out,
    /// as analysis refuses them.
    func filesToAnalyze() throws -> [(path: String, stamp: FileStamp)] {
        try statement(
            """
            SELECT f.path, f.size_bytes, f.modified_seconds FROM tracks t
            JOIN files f ON f.id = t.file_id LEFT JOIN \(currentMeasuresJoin)
            WHERE m.path IS NULL
            ORDER BY f.path
            """
        ).map { row in
            (
                try row.text(0),
                FileStamp(sizeBytes: try row.int(1), modifiedSeconds: try row.double(2))
            )
        }.filter { !dsdFileExtensions.contains(($0.path as NSString).pathExtension.lowercased()) }
    }

    /// Keeps `measures` for `path` as `stamp` describes the file, replacing any row before.
    func storeMeasures(_ measures: FileMeasures, path: String, stamp: FileStamp) throws {
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
