import Foundation
import Metadata

/// What the Discogs survey keeps of one file: the fields its report compares, what the matcher's
/// tuning compares (ADR 0131), and every custom key. One JSON line each in `files.jsonl`.
struct SurveyRecord: Codable, Equatable, Sendable {
    var path: String
    /// `FileFormat`'s raw value; nil when the file couldn't be read.
    var format: String?
    var failure: String?
    var album: String?
    var albumArtist: String?
    var artist: String?
    var compilation = false
    var genre: String?
    var mood: String?
    var grouping: String?
    /// The record label, `LABEL` in Vorbis comments.
    var label: String?
    var catalogNumber: String?
    var media: String?
    var date: String?
    var title: String?
    var trackNumber: Int?
    var discNumber: Int?
    var barcode: String?
    /// The audio's length. Not optional, so a line from before the tuning fails to load rather
    /// than reading as a file of no length.
    var seconds = 0.0
    var custom: [String: String] = [:]

    init(path: String, failure: String) {
        self.path = path
        self.failure = failure
    }

    init(path: String, format: String, metadata: TrackMetadata) {
        let tags = metadata.tags
        self.path = path
        self.format = format
        album = tags.album
        albumArtist = tags.albumArtist
        artist = tags.artist
        compilation = tags.compilation
        genre = tags.genre
        mood = tags.mood
        grouping = tags.grouping
        label = tags.publisher
        catalogNumber = tags.catalogNumber
        media = tags.media
        date = tags.date
        title = tags.title
        trackNumber = tags.trackNumber
        discNumber = tags.discNumber
        barcode = tags.barcode
        seconds = Double(metadata.audio.lengthFrames) / Double(metadata.audio.sampleRateHz)
        custom = tags.custom
    }

    /// The album the library would put the file in: its title and album artist, else its
    /// artist unless it's a compilation. A file without an album title is its folder's.
    var albumKey: String {
        guard let album else { return "folder:" + (path as NSString).deletingLastPathComponent }
        return album + "\u{1F}" + (albumArtist ?? (compilation ? "" : artist ?? ""))
    }
}
