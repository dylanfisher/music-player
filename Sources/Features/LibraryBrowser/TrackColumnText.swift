import DisplayText
import Foundation
import Library
import Metadata
import Settings

extension TrackColumn {
    /// Numbers line up on the right.
    var isNumeric: Bool {
        switch self {
        case .rowNumber, .trackNumber, .trackTotal, .trackOfTotal, .discNumber, .discTotal,
            .discOfTotal, .year, .duration, .sampleRate, .bitDepth, .bitRate, .channels, .size,
            .bpm, .movementNumber, .playCount, .skipCount, .playlistOrder, .cutoff, .effectiveBits,
            .dynamicRange, .truePeak:
            true
        default: false
        }
    }

    /// The width a column gets when it's first shown from the header's menu, in points: enough
    /// for a typical value, so the owner's sixteen columns fit beside the sidebar and the queue
    /// on a 1440-point screen.
    public var defaultWidth: Double {
        switch self {
        case .rowNumber: 30
        // The playing mark and the insets beside it; the narrowest a column may be.
        case .nowPlaying: 20
        case .trackNumber, .discNumber, .year, .channels, .bpm, .playCount, .skipCount, .loved,
            .compilation, .art:
            34
        case .duration, .trackTotal, .discTotal, .movementNumber, .bitDepth, .playlistOrder,
            .dynamicRange:
            40
        case .size, .codec, .fileType: 48
        case .rating: 50
        case .bitRate, .effectiveBits: 55
        case .cutoff, .truePeak: 70
        case .sampleRate: 76
        case .trackOfTotal, .discOfTotal: 84
        case .dateAdded, .dateCreated, .dateModified, .lastPlayed: 86
        case .artist, .album, .albumArtist, .composer, .conductor, .lyricist, .publisher: 72
        case .title, .fileName, .path, .comment, .description, .work, .movementName: 88
        default: 60
        }
    }

    /// What the column shows for `row`, the table's row `position`. Empty where the tags and
    /// stats say nothing, for Album Art, which is an image, and for Now Playing, which the
    /// table fills on the playing row.
    @MainActor func text(_ row: TrackRow, position: Int) -> String {
        switch self {
        // The row's place in the list, which is the playlist's order when sorted by it.
        case .rowNumber, .playlistOrder: String(position + 1)
        case .art, .nowPlaying: ""
        case .title: row.title
        case .artist: row.artist ?? ""
        case .album: row.album ?? ""
        case .albumArtist: row.albumArtist ?? ""
        case .composer: row.composer ?? ""
        case .conductor: row.conductor ?? ""
        case .lyricist: row.lyricist ?? ""
        case .grouping: row.grouping ?? ""
        case .work: row.work ?? ""
        case .movementNumber: number(row.movementNumber)
        case .movementName: row.movementName ?? ""
        case .genre: row.genre ?? ""
        case .year: number(row.year)
        case .originalDate: row.originalDate ?? ""
        case .trackNumber: number(row.trackNumber)
        case .trackTotal: number(row.trackTotal)
        case .trackOfTotal: ofTotal(row.trackNumber, row.trackTotal)
        case .discNumber: number(row.discNumber)
        case .discTotal: number(row.discTotal)
        case .discOfTotal: ofTotal(row.discNumber, row.discTotal)
        case .discSubtitle: row.discSubtitle ?? ""
        case .compilation: row.compilation ? "Yes" : ""
        case .duration: clock(row.durationSeconds)
        case .bpm: number(row.bpm)
        case .key: row.key ?? ""
        case .codec: row.codec.uppercased()
        case .fileType: row.fileType
        case .bitRate: row.bitRateKbps.map(kbpsText) ?? ""
        case .sampleRate: sampleRateText(row.sampleRateHz)
        case .bitDepth: number(row.bitsPerSample)
        case .channels: String(row.channels)
        case .cutoff: row.cutoffHz.map { "\(kilohertzText($0)) kHz" } ?? ""
        case .effectiveBits: number(row.effectiveBits)
        case .dynamicRange: row.dynamicRange.map(dynamicRangeText) ?? ""
        case .truePeak: row.truePeakDBTP.map(truePeakText) ?? ""
        case .size:
            ByteCountFormatter.string(fromByteCount: Int64(row.sizeBytes), countStyle: .file)
        case .fileName: row.fileName
        case .path: row.path
        case .dateAdded: date(row.addedSeconds)
        case .dateCreated: row.createdSeconds.map(date) ?? ""
        case .dateModified: date(row.modifiedSeconds)
        case .playCount: row.playCount > 0 ? String(row.playCount) : ""
        case .skipCount: row.skipCount > 0 ? String(row.skipCount) : ""
        case .lastPlayed: row.lastPlayedSeconds.map(date) ?? ""
        case .rating: stars(row.rating)
        case .loved: row.loved ? "\u{2665}" : ""
        case .publisher: row.publisher ?? ""
        case .catalogNumber: row.catalogNumber ?? ""
        case .barcode: row.barcode ?? ""
        case .copyright: row.copyright ?? ""
        case .encoder: row.encoder ?? ""
        case .comment: row.comment ?? ""
        case .description: row.description ?? ""
        }
    }
}

private func number(_ value: Int?) -> String { value.map(String.init) ?? "" }

/// "3 of 12", "3" without a total, and nothing without a number.
private func ofTotal(_ number: Int?, _ total: Int?) -> String {
    guard let number else { return "" }
    return total.map { "\(number) of \($0)" } ?? String(number)
}

@MainActor private func date(_ seconds: Double) -> String {
    dateFormat.string(from: Date(timeIntervalSince1970: seconds))
}

/// Dates and times as the table shows them: short, in the user's locale.
@MainActor let dateFormat: DateFormatter = {
    let format = DateFormatter()
    format.dateStyle = .short
    format.timeStyle = .short
    return format
}()
