import Foundation
import SQLite

/// A catalog in place, as the tagger window describes it (51.28).
public struct CatalogStatus: Equatable, Sendable {
    /// The date of the dump it was built from, as the dump's file names have it.
    public var dumpDate: String
    /// When its import finished. The catalog doesn't store the time, but nothing writes the
    /// file after the import swaps it in (the app opens it read-only), so its modification
    /// date is that time.
    public var importedAt: Date
    public var sizeBytes: Int
    public var url: URL

    /// The catalog at `url`, opened to check it's one this build reads. Throws as
    /// `Catalog(at:)` does.
    public init(at url: URL) throws {
        dumpDate = try Catalog(at: url).dumpDate
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let modified = attributes[.modificationDate] as? Date else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        importedAt = modified
        sizeBytes = try Database.sizeBytes(at: url)
        self.url = url
    }

    init(dumpDate: String, importedAt: Date, sizeBytes: Int, url: URL) {
        self.dumpDate = dumpDate
        self.importedAt = importedAt
        self.sizeBytes = sizeBytes
        self.url = url
    }
}
