import Foundation

/// A field every tag format maps its own keys onto, so the rules for values live in one place.
package enum TagField: String, CaseIterable, Sendable {
    case title, artist, album, albumArtist, genre, date, composer, comment
    /// "3" or "3/12".
    case track, disc
    case trackTotal, discTotal
    /// "1" or "0".
    case compilation
    case grouping, catalogNumber, barcode, key, conductor, lyricist, publisher, copyright,
        encoder, description, discSubtitle, work, movementName, originalDate
    case titleSort, artistSort, albumSort, albumArtistSort, composerSort
    case remixer, originalArtist, originalAlbum, isrc, language, mood, media, lyrics
    /// Webpages, which ID3 holds in URL frames.
    case artistURL, audioFileURL, audioSourceURL, commercialURL, copyrightURL, paymentURL,
        publisherURL, radioStationURL
    /// "128" or "127.9".
    case bpm
    /// "2" or "2/4".
    case movement
    case movementTotal

    /// The property a field of plain text sets; nil for numbers and the compilation flag.
    package var textProperty: WritableKeyPath<TrackTags, String?>? {
        switch self {
        case .title: \.title
        case .artist: \.artist
        case .album: \.album
        case .albumArtist: \.albumArtist
        case .genre: \.genre
        case .date: \.date
        case .composer: \.composer
        case .comment: \.comment
        case .grouping: \.grouping
        case .catalogNumber: \.catalogNumber
        case .barcode: \.barcode
        case .key: \.key
        case .conductor: \.conductor
        case .lyricist: \.lyricist
        case .publisher: \.publisher
        case .copyright: \.copyright
        case .encoder: \.encoder
        case .description: \.description
        case .discSubtitle: \.discSubtitle
        case .work: \.work
        case .movementName: \.movementName
        case .originalDate: \.originalDate
        case .titleSort: \.titleSort
        case .artistSort: \.artistSort
        case .albumSort: \.albumSort
        case .albumArtistSort: \.albumArtistSort
        case .composerSort: \.composerSort
        case .remixer: \.remixer
        case .originalArtist: \.originalArtist
        case .originalAlbum: \.originalAlbum
        case .isrc: \.isrc
        case .language: \.language
        case .mood: \.mood
        case .media: \.media
        case .lyrics: \.lyrics
        case .artistURL: \.artistURL
        case .audioFileURL: \.audioFileURL
        case .audioSourceURL: \.audioSourceURL
        case .commercialURL: \.commercialURL
        case .copyrightURL: \.copyrightURL
        case .paymentURL: \.paymentURL
        case .publisherURL: \.publisherURL
        case .radioStationURL: \.radioStationURL
        case .track, .disc, .trackTotal, .discTotal, .compilation, .bpm, .movement,
            .movementTotal:
            nil
        }
    }
}

/// Names that Vorbis comment keys, ID3 `TXXX` descriptions and MP4 freeform `name` atoms spell
/// alike in MusicBrainz Picard's tag mapping, compared uppercased (ADR 0006).
enum SharedTagName {
    static let catalogNumber = "CATALOGNUMBER"
    static let barcode = "BARCODE"
    static let conductor = "CONDUCTOR"
    static let lyricist = "LYRICIST"
    static let label = "LABEL"
    static let discSubtitle = "DISCSUBTITLE"
    static let work = "WORK"
    static let originalDate = "ORIGINALDATE"
    static let description = "DESCRIPTION"
    static let mood = "MOOD"
    static let remixer = "REMIXER"
    static let originalArtist = "ORIGINALARTIST"
    static let originalAlbum = "ORIGINALALBUM"
    static let isrc = "ISRC"
    static let language = "LANGUAGE"
    static let media = "MEDIA"
    /// Mp3tag's names for ID3's URL frames, which Picard doesn't map.
    static let artistURL = "WWWARTIST"
    static let audioFileURL = "WWWAUDIOFILE"
    static let audioSourceURL = "WWWAUDIOSOURCE"
    static let commercialURL = "WWWCOMMERCIALINFO"
    static let copyrightURL = "WWWCOPYRIGHT"
    static let paymentURL = "WWWPAYMENT"
    static let publisherURL = "WWWPUBLISHER"
    static let radioStationURL = "WWWRADIOPAGE"
}

extension TrackTags {
    /// Sets `field` from its text form unless it already has a value. Empty text counts as no
    /// value. A value that doesn't parse is read in part or dropped, with a warning naming
    /// `offset`, where the value sits in the file. Text is read up to a NUL, as ID3 reads it,
    /// since SQLite's LIKE stops there too and a rule would match only part of the text; a NUL
    /// with text after it warns.
    mutating func set(
        _ field: TagField, _ text: String, at offset: Int, warnings: inout [MetadataWarning]
    ) {
        let text = upToNUL(text, at: offset, &warnings)
        guard !text.isEmpty else { return }
        if let property = field.textProperty {
            self[keyPath: property] = self[keyPath: property] ?? text
            return
        }
        switch field {
        case .bpm: bpm = bpm ?? beatsPerMinute(text, at: offset, &warnings)
        case .movement:
            let (number, total) = numberPair(text, field, at: offset, &warnings)
            movementNumber = movementNumber ?? number
            movementTotal = movementTotal ?? total
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
        case .movementTotal:
            movementTotal = movementTotal ?? wholeNumber(text, field, at: offset, &warnings)
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
        default: preconditionFailure("\(field) is text, set above")
        }
    }

    /// Sets the custom key `name`, uppercased, from `text` unless it already has a value, with
    /// `set`'s rules for empty text and a NUL.
    mutating func setCustom(
        _ name: String, _ text: String, at offset: Int, warnings: inout [MetadataWarning]
    ) {
        let text = upToNUL(text, at: offset, &warnings)
        guard !name.isEmpty, !text.isEmpty else { return }
        custom[name.uppercased()] = custom[name.uppercased()] ?? text
    }

    /// Fields this lacks, taken from `other`.
    func filling(from other: TrackTags) -> TrackTags {
        var result = self
        for field in TagField.allCases.compactMap(\.textProperty) {
            result[keyPath: field] = self[keyPath: field] ?? other[keyPath: field]
        }
        let numbers: [WritableKeyPath<TrackTags, Int?>] = [
            \.trackNumber, \.trackTotal, \.discNumber, \.discTotal, \.bpm, \.movementNumber,
            \.movementTotal,
        ]
        for field in numbers {
            result[keyPath: field] = self[keyPath: field] ?? other[keyPath: field]
        }
        result.compilation = compilation || other.compilation
        result.custom = custom.merging(other.custom) { mine, _ in mine }
        return result
    }
}

/// `text` up to its first NUL, with a warning naming `offset` when text follows the NUL.
private func upToNUL(_ text: String, at offset: Int, _ warnings: inout [MetadataWarning])
    -> String
{
    guard let nul = text.firstIndex(of: "\u{0}") else { return text }
    if text[nul...].contains(where: { $0 != "\u{0}" }) {
        warnings.append(
            MetadataWarning(
                kind: .badText, offset: offset, detail: "text holds a NUL; read up to it"))
    }
    return String(text[..<nul])
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

/// A tempo, which taggers write whole or with decimals, rounded to a whole number. Text that
/// isn't a positive number is dropped with a warning.
private func beatsPerMinute(
    _ text: String, at offset: Int, _ warnings: inout [MetadataWarning]
) -> Int? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard trimmed.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
        let value = Double(trimmed), value.isFinite, value < Double(Int32.max)
    else {
        warnings.append(
            MetadataWarning(
                kind: .badNumber, offset: offset,
                detail: "\(TagField.bpm.rawValue) \"\(text)\" isn't a number; dropped"))
        return nil
    }
    let rounded = Int(value.rounded())
    return rounded == 0 ? nil : rounded
}
