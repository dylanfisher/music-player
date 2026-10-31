import Foundation

/// A field every tag format maps its own keys onto, so the rules for values live in one place.
enum TagField: String {
    case title, artist, album, albumArtist, genre, date, composer, comment
    /// "3" or "3/12".
    case track, disc
    case trackTotal, discTotal
    /// "1" or "0".
    case compilation
}

extension TrackTags {
    /// Sets `field` from its text form unless it already has a value. Empty text counts as no
    /// value. A value that doesn't parse is read in part or dropped, with a warning naming
    /// `offset`, where the value sits in the file.
    mutating func set(
        _ field: TagField, _ text: String, at offset: Int, warnings: inout [MetadataWarning]
    ) {
        guard !text.isEmpty else { return }
        switch field {
        case .title: title = title ?? text
        case .artist: artist = artist ?? text
        case .album: album = album ?? text
        case .albumArtist: albumArtist = albumArtist ?? text
        case .genre: genre = genre ?? text
        case .date: date = date ?? text
        case .composer: composer = composer ?? text
        case .comment: comment = comment ?? text
        case .track:
            let (number, total) = numberPair(text, field, at: offset, &warnings)
            trackNumber = trackNumber ?? number
            trackTotal = trackTotal ?? total
        case .disc:
            let (number, total) = numberPair(text, field, at: offset, &warnings)
            discNumber = discNumber ?? number
            discTotal = discTotal ?? total
        case .trackTotal:
            trackTotal = trackTotal ?? wholeNumber(text, field, at: offset, &warnings)
        case .discTotal:
            discTotal = discTotal ?? wholeNumber(text, field, at: offset, &warnings)
        case .compilation:
            switch text {
            case "1": compilation = true
            case "0": break
            default:
                warnings.append(
                    MetadataWarning(
                        kind: .badValue, offset: offset,
                        detail: "compilation flag \"\(text)\" isn't 1 or 0; ignored"))
            }
        }
    }

    /// Fields this lacks, taken from `other`.
    func filling(from other: TrackTags) -> TrackTags {
        TrackTags(
            title: title ?? other.title, artist: artist ?? other.artist,
            album: album ?? other.album, albumArtist: albumArtist ?? other.albumArtist,
            genre: genre ?? other.genre, date: date ?? other.date,
            trackNumber: trackNumber ?? other.trackNumber,
            trackTotal: trackTotal ?? other.trackTotal,
            discNumber: discNumber ?? other.discNumber, discTotal: discTotal ?? other.discTotal,
            compilation: compilation || other.compilation, composer: composer ?? other.composer,
            comment: comment ?? other.comment)
    }
}

/// "3" or "3/12", with spaces around either number allowed. A missing total is nil, and so is a
/// zero, which taggers write for "not set" as MP4 does.
private func numberPair(
    _ text: String, _ field: TagField, at offset: Int, _ warnings: inout [MetadataWarning]
) -> (Int?, Int?) {
    let parts = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
    let number = wholeNumber(String(parts[0]), field, at: offset, &warnings)
    guard parts.count == 2 else { return (number, nil) }
    return (number, wholeNumber(String(parts[1]), field, at: offset, &warnings))
}

/// The leading digits of `text` once trimmed, so "3 of 10" reads as 3 and "A1" as nothing, each
/// with a warning. Nil for zero.
private func wholeNumber(
    _ text: String, _ field: TagField, at offset: Int, _ warnings: inout [MetadataWarning]
) -> Int? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    let digits = trimmed.prefix { $0.isASCII && $0.isNumber }
    let value = Int(digits)
    if digits.count != trimmed.count || (!digits.isEmpty && value == nil) {
        warnings.append(
            MetadataWarning(
                kind: .badNumber, offset: offset,
                detail: "\(field.rawValue) \"\(text)\" isn't a number; "
                    + (value.map { "read as \($0)" } ?? "dropped")))
    }
    return value == 0 ? nil : value
}
