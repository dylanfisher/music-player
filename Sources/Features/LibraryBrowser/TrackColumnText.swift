import DisplayText
import Foundation
import Library
import Settings

extension TrackColumn {
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

@MainActor private let dateFormat: DateFormatter = {
    let format = DateFormatter()
    format.dateStyle = .short
    format.timeStyle = .short
    return format
}()
