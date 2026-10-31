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
    /// value. `offset` is where the value sits in the file, for the error when it doesn't parse.
    mutating func set(_ field: TagField, _ text: String, at offset: Int) throws(ParseFailure) {
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
            let (number, total) = try numberPair(text, field, at: offset)
            trackNumber = trackNumber ?? number
            trackTotal = trackTotal ?? total
        case .disc:
            let (number, total) = try numberPair(text, field, at: offset)
            discNumber = discNumber ?? number
            discTotal = discTotal ?? total
        case .trackTotal:
            if trackTotal == nil { trackTotal = try wholeNumber(text, field, at: offset) }
        case .discTotal:
            if discTotal == nil { discTotal = try wholeNumber(text, field, at: offset) }
        case .compilation:
            switch text {
            case "1": compilation = true
            case "0": break
            default: throw .malformed(at: offset, "compilation flag \"\(text)\" isn't 1 or 0")
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
private func numberPair(_ text: String, _ field: TagField, at offset: Int) throws(ParseFailure)
    -> (Int?, Int?)
{
    let parts = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
    let number = try wholeNumber(String(parts[0]), field, at: offset)
    guard parts.count == 2 else { return (number, nil) }
    return (number, try wholeNumber(String(parts[1]), field, at: offset))
}

/// Nil for zero.
private func wholeNumber(_ text: String, _ field: TagField, at offset: Int) throws(ParseFailure)
    -> Int?
{
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard trimmed.allSatisfy(\.isASCII), trimmed.allSatisfy(\.isNumber), let value = Int(trimmed)
    else {
        throw .malformed(at: offset, "\(field.rawValue) \"\(text)\" isn't a number")
    }
    return value == 0 ? nil : value
}
