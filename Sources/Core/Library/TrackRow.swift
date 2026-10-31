import Foundation
import Metadata

/// One track as the track table, the queue and now playing show it.
public struct TrackRow: Equatable, Sendable {
    /// The file's ID, which is also the track's.
    public var id: Int64
    public var path: String
    /// The title tag, or the file name without its extension.
    public var title: String
    public var artist: String?
    public var album: String?
    public var albumID: Int64?
    public var albumArtist: String?
    public var genre: String?
    /// The date tag as written, such as "1969" or "1969-09-26".
    public var date: String?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var codec: String
    public var sampleRateHz: Int
    public var bitsPerSample: Int?
    public var durationSeconds: Double
    /// When the scanner first indexed the file, in seconds since 1970.
    public var addedSeconds: Double
    public var art: EmbeddedArt?

    /// The year the date tag starts with, which is what the year column sorts by.
    public var year: Int? {
        guard let date, date.count >= 4 else { return nil }
        return Int(date.prefix(4))
    }
}
