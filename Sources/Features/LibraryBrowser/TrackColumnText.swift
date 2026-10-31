import DisplayText
import Foundation
import Library
import Settings

extension TrackColumn {
    /// The column's header.
    public var title: String {
        switch self {
        case .title: "Title"
        case .artist: "Artist"
        case .album: "Album"
        case .albumArtist: "Album Artist"
        case .trackNumber: "#"
        case .discNumber: "Disc"
        case .year: "Year"
        case .genre: "Genre"
        case .duration: "Time"
        case .codec: "Format"
        case .sampleRate: "Sample Rate"
        case .bitDepth: "Bits"
        case .dateAdded: "Date Added"
        case .path: "Path"
        case .playCount: "Plays"
        case .skipCount: "Skips"
        case .lastPlayed: "Last Played"
        case .rating: "Rating"
        case .playlistOrder: "Order"
        }
    }

    /// Numbers line up on the right.
    var isNumeric: Bool {
        switch self {
        case .trackNumber, .discNumber, .year, .duration, .sampleRate, .bitDepth, .playCount,
            .skipCount, .playlistOrder:
            true
        default: false
        }
    }

    /// What the column shows for `row`, the table's row `position`. Empty where the tags and
    /// stats say nothing.
    @MainActor func text(_ row: TrackRow, position: Int) -> String {
        switch self {
        case .title: row.title
        case .artist: row.artist ?? ""
        case .album: row.album ?? ""
        case .albumArtist: row.albumArtist ?? ""
        case .trackNumber: row.trackNumber.map(String.init) ?? ""
        case .discNumber: row.discNumber.map(String.init) ?? ""
        case .year: row.year.map(String.init) ?? ""
        case .genre: row.genre ?? ""
        case .duration: clock(row.durationSeconds)
        case .codec: row.codec.uppercased()
        case .sampleRate: "\(kilohertz(Double(row.sampleRateHz))) kHz"
        case .bitDepth: row.bitsPerSample.map(String.init) ?? ""
        case .dateAdded: dateFormat.string(from: Date(timeIntervalSince1970: row.addedSeconds))
        case .path: row.path
        case .playCount: row.playCount > 0 ? String(row.playCount) : ""
        case .skipCount: row.skipCount > 0 ? String(row.skipCount) : ""
        case .lastPlayed:
            row.lastPlayedSeconds.map { dateFormat.string(from: Date(timeIntervalSince1970: $0)) }
                ?? ""
        case .rating: stars(row.rating)
        // The row's place in the list, which is the playlist's order when sorted by it.
        case .playlistOrder: String(position + 1)
        }
    }
}

/// A rating as stars, empty when unrated.
public func stars(_ count: Int) -> String {
    String(repeating: "★", count: count)
}

@MainActor private let dateFormat: DateFormatter = {
    let format = DateFormatter()
    format.dateStyle = .short
    format.timeStyle = .short
    return format
}()
