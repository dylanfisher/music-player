import CacheFolder
import Foundation
import Log

private let logger = moduleLogger()

/// The covers fetched from Discogs, kept on disk by their image URL beside the thumbnails
/// (ADR 0079, 0189), so a Get Artwork stopped by a quit or a crash fetches only the covers it
/// hadn't reached when it's run again. A cache, not app state: a file that can't be read or
/// written is logged and the cover fetched again. Least recently used goes first once it holds
/// more than `capacityBytes`. Safe to use from any thread.
public final class CoverStore: Sendable {
    /// About 7,000 of Discogs's 600-pixel covers, more than the releases of a large library.
    static let capacityBytes = 1_000_000_000
    /// Bytes written between trims.
    static let trimEveryBytes = capacityBytes / 10

    private let folder: CacheFolder

    public convenience init(directory: URL) {
        self.init(directory: directory, capacityBytes: Self.capacityBytes)
    }

    init(directory: URL, capacityBytes: Int) {
        folder = CacheFolder(
            directory: directory, noun: "Discogs cover", capacityBytes: capacityBytes,
            trimEveryBytes: Self.trimEveryBytes, report: { logger.error("\($0)") })
    }

    /// The image fetched from `url`, checked again as a cover; nil when none is stored, or the
    /// one stored no longer passes, which is then removed.
    func cover(from url: URL) -> Cover? {
        let key = [url.absoluteString]
        guard let bytes = folder.data(key) else { return nil }
        do {
            return try Cover(checking: Array(bytes))
        } catch {
            folder.discard(key, because: "isn't a cover: \(error)")
            return nil
        }
    }

    /// Keeps `cover`, fetched from `url`.
    func store(_ cover: Cover, from url: URL) {
        folder.store(cover.bytes, [url.absoluteString], of: url.absoluteString)
    }

    /// The file a cover from `url` is kept in, for the tests.
    func fileURL(from url: URL) -> URL { folder.fileURL([url.absoluteString]) }
}
