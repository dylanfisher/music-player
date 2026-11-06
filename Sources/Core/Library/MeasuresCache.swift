import Foundation
import Metadata

/// The analysis's stored measures (phase 45), on a connection of its own, so an analysis
/// never waits for the window's queries or holds them up.
public actor MeasuresCache {
    private let index: LibraryIndex

    public init(databaseURL: URL) throws {
        index = try LibraryIndex(at: databaseURL)
    }

    /// The measures of `path`, when they were made from the file as `stamp` describes it.
    public func measures(path: String, stamp: FileStamp) throws -> FileMeasures? {
        try index.measures(path: path, stamp: stamp)
    }

    /// What Analyze Library has done and has left: the files with no measures, or whose file
    /// changed since, or measured before a run again started (ADR 0119).
    public func analysisFiles() throws -> AnalysisFiles {
        try index.analysisFiles()
    }

    /// Starts a run, `again` over every file, or else over what's left.
    public func beginRun(again: Bool) throws {
        try index.beginAnalysisRun(again: again)
    }

    public func finishRun() throws {
        try index.finishAnalysisRun()
    }

    public func recordFailure(path: String, stamp: FileStamp) throws {
        try index.recordAnalysisFailure(path: path, stamp: stamp)
    }

    public func store(_ measures: FileMeasures, path: String, stamp: FileStamp) throws {
        try index.storeMeasures(measures, path: path, stamp: stamp)
    }
}
