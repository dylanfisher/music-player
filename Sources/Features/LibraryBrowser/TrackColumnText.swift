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
        }
    }

    /// Numbers line up on the right.
    var isNumeric: Bool {
        switch self {
        case .trackNumber, .discNumber, .year, .duration, .sampleRate, .bitDepth: true
        default: false
        }
    }

    /// What the column shows for `row`. Empty where the tags say nothing.
    @MainActor func text(_ row: TrackRow) -> String {
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
        case .dateAdded:
            dateAddedFormat.string(from: Date(timeIntervalSince1970: row.addedSeconds))
        case .path: row.path
        }
    }
}

@MainActor private let dateAddedFormat: DateFormatter = {
    let format = DateFormatter()
    format.dateStyle = .short
    format.timeStyle = .short
    return format
}()
