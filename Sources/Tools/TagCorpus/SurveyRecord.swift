import Foundation
import Metadata

/// What the Discogs survey keeps of one file: the fields its report compares, and every custom
/// key. One JSON line each in `files.jsonl`.
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
    var custom: [String: String] = [:]

    init(path: String, failure: String) {
        self.path = path
        self.failure = failure
    }

    init(path: String, format: String, tags: TrackTags) {
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
        custom = tags.custom
    }

    /// The album the library would put the file in: its title and album artist, else its
    /// artist unless it's a compilation. A file without an album title is its folder's.
    var albumKey: String {
        guard let album else { return "folder:" + (path as NSString).deletingLastPathComponent }
        return album + "\u{1F}" + (albumArtist ?? (compilation ? "" : artist ?? ""))
    }
}
