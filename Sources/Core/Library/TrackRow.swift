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
    /// The artist the album is listed under, as `BrowserEntry.artist` names it: the album
    /// artist, else the track artist; nil for a compilation without one.
    public var albumEntryArtist: String? = nil
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
    public var playCount = 0
    public var skipCount = 0
    /// Seconds since 1970; nil when never played.
    public var lastPlayedSeconds: Double? = nil
    /// Stars, 0 to `SmartField.maxRating`; 0 is unrated.
    public var rating = 0
    public var loved = false
    public var trackTotal: Int? = nil
    public var discTotal: Int? = nil
    public var compilation = false
    public var composer: String? = nil
    public var comment: String? = nil
    public var channels = 0
    public var sizeBytes = 0
    /// Kilobits a second, as `TrackColumn.bitRate` sorts by; nil for a track of no length.
    public var bitRateKbps: Double? = nil
    public var fileName = ""
    /// The extension, uppercased.
    public var fileType = ""
    /// Seconds since 1970; nil where the volume keeps no creation date.
    public var createdSeconds: Double? = nil
    public var modifiedSeconds = 0.0
    public var grouping: String? = nil
    public var catalogNumber: String? = nil
    public var barcode: String? = nil
    public var bpm: Int? = nil
    public var key: String? = nil
    public var conductor: String? = nil
    public var lyricist: String? = nil
    public var publisher: String? = nil
    public var copyright: String? = nil
    public var encoder: String? = nil
    public var description: String? = nil
    public var discSubtitle: String? = nil
    public var work: String? = nil
    public var movementNumber: Int? = nil
    public var movementName: String? = nil
    public var originalDate: String? = nil

    /// The year the date tag starts with, which is what the year column sorts by.
    public var year: Int? {
        guard let date, date.count >= 4 else { return nil }
        return Int(date.prefix(4))
    }
}
