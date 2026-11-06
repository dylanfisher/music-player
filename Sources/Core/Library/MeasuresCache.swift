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

    /// The tracks' files Analyze Library has still to analyze, with the index's stamp for each:
    /// those with no measures, or whose file changed since.
    public func filesToAnalyze() throws -> [(path: String, stamp: FileStamp)] {
        try index.filesToAnalyze()
    }

    public func store(_ measures: FileMeasures, path: String, stamp: FileStamp) throws {
        try index.storeMeasures(measures, path: path, stamp: stamp)
    }
}
