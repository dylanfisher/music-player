import Foundation
import Metadata

/// The calls a scan makes to the volume it scans. `SystemFileAccess` makes them; the bench and
/// tests wrap it to add a NAS's latency, which this machine can't otherwise show.
public protocol ScanFileAccess: Sendable {
    /// Whether `path` is on a local volume, or nil when the volume doesn't say.
    func volumeIsLocal(_ path: String) throws -> Bool?
    /// The entries of `directory`, without hidden ones, each with `keys` already fetched.
    func contentsOfDirectory(_ directory: String, keys: [URLResourceKey]) throws -> [URL]
    func readMetadata(at path: String) throws(MetadataError) -> ParsedFile
}

public struct SystemFileAccess: ScanFileAccess {
    public let hints: ReadHints

    public init(hints: ReadHints = .all) {
        self.hints = hints
    }

    public func volumeIsLocal(_ path: String) throws -> Bool? {
        try URL(fileURLWithPath: path, isDirectory: true).resourceValues(forKeys: [
            .volumeIsLocalKey
        ]).volumeIsLocal
    }

    public func contentsOfDirectory(_ directory: String, keys: [URLResourceKey]) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: directory, isDirectory: true),
            includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
    }

    public func readMetadata(at path: String) throws(MetadataError) -> ParsedFile {
        // Without `isDirectory`, Foundation stats the path to find out, once more per file.
        try Metadata.readMetadata(at: URL(fileURLWithPath: path, isDirectory: false), hints: hints)
    }
}
