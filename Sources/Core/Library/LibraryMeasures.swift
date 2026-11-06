import Metadata

extension LibraryIndex {
    /// The measures stored for `path`, when they were made from the file as `stamp` describes
    /// it; nil when there are none or the file has changed since.
    func measures(path: String, stamp: FileStamp) throws -> FileMeasures? {
        try statement(
            """
            SELECT format_id, sample_rate_hz, stored_bits, channels, is_float, duration_seconds,
                cutoff_hz, cutoff_steepness_db_per_khz, effective_bits, identical_channels,
                peak_dbfs, true_peak_dbtp, clipped_runs, dynamic_range
            FROM \(measuresTable)
            WHERE path = ? AND size_bytes = ? AND modified_seconds = ?
            """
        ).map(path, stamp.sizeBytes, stamp.modifiedSeconds) { row in
            FileMeasures(
                formatID: try row.text(0), sampleRateHz: try row.double(1),
                storedBits: row.optionalInt(2), channels: try row.int(3),
                isFloat: try row.int(4) != 0, durationSeconds: try row.double(5),
                cutoffHz: row.optionalDouble(6), cutoffSteepnessDBPerKHz: row.optionalDouble(7),
                effectiveBits: row.optionalInt(8),
                identicalChannels: row.optionalInt(9).map { $0 != 0 },
                peakDBFS: row.optionalDouble(10), truePeakDBTP: row.optionalDouble(11),
                clippedRuns: try row.int(12), dynamicRange: row.optionalInt(13))
        }.first
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
