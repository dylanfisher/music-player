import Foundation
import HALOutput
import Library
import Log
import Metadata

private let logger = moduleLogger()

/// Analysis behind its two caches: the measures in the index and the spectrograms in the
/// Caches folder, each kept for the file as its size and modification time describe it, so a
/// file that changed is analyzed again (ADR 0115). The analysis runs on a task of its own at
/// utility priority, cancelled with the task that awaits it. A cache that can't be read or
/// written, as the index while a scan holds it past its timeout, is logged and the file
/// analyzed, or its result returned, without it.
public final class FileAnalyzer: Sendable {
    private let measures: MeasuresCache
    private let spectrograms: SpectrogramStore
    private let latency: FileLatency?

    /// `latency` makes every read wait as on a network volume, for benchmarks.
    public init(
        measures: MeasuresCache, spectrograms: SpectrogramStore, latency: FileLatency? = nil
    ) {
        self.measures = measures
        self.spectrograms = spectrograms
        self.latency = latency
    }

    /// The measures and spectrogram of the file at `path`, from the caches when both hold it
    /// as it is now. `progress` hears the share read, and 1 for a file found in the caches.
    public func result(
        of path: String, progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> AnalysisResult {
        let stamp = try await offMain { try fileStamp(path) }
        if let measured = await cachedMeasures(path, stamp: stamp),
            let spectrogram = await offMain({
                self.spectrograms.spectrogram(path: path, stamp: stamp)
            })
        {
            progress(1)
            return AnalysisResult(measures: measured, spectrogram: spectrogram)
        }
        return try await analyzed(path, stamp: stamp, progress: progress)
    }

    /// The measures of the file at `path`, from the index when it holds them for the file as it
    /// is now, which needs no spectrogram.
    public func measures(
        of path: String, progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> FileMeasures {
        let stamp = try await offMain { try fileStamp(path) }
        if let measured = await cachedMeasures(path, stamp: stamp) {
            progress(1)
            return measured
        }
        return try await analyzed(path, stamp: stamp, progress: progress).measures
    }

    private func analyzed(
        _ path: String, stamp: FileStamp, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> AnalysisResult {
        let latency = latency
        let result = try await offMain {
            try analyzeFile(
                at: URL(fileURLWithPath: path, isDirectory: false), latency: latency,
                progress: progress)
        }
        do {
            try await measures.store(result.measures, path: path, stamp: stamp)
        } catch {
            logger.error("couldn't keep the measures of \(path): \(error)")
        }
        await offMain { self.spectrograms.store(result.spectrogram, path: path, stamp: stamp) }
        return result
    }

    private func cachedMeasures(_ path: String, stamp: FileStamp) async -> FileMeasures? {
        do {
            return try await measures.measures(path: path, stamp: stamp)
        } catch {
            logger.error("couldn't read the kept measures of \(path): \(error)")
            return nil
        }
    }
}

/// `body` on a task of its own at utility priority, cancelled when the caller's task is.
private func offMain<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async rethrows
    -> T
{
    let task = Task.detached(priority: .utility) { try body() }
    return try await withTaskCancellationHandler {
        try await task.value
    } onCancel: {
        task.cancel()
    }
}

/// The file's size and modification time, as the directory walk reads them.
private func fileStamp(_ path: String) throws -> FileStamp {
    let values = try URL(fileURLWithPath: path, isDirectory: false).resourceValues(
        forKeys: [.fileSizeKey, .contentModificationDateKey])
    guard let size = values.fileSize, let modified = values.contentModificationDate else {
        throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: path])
    }
    return FileStamp(sizeBytes: size, modifiedSeconds: modified.timeIntervalSince1970)
}
