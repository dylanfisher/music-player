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
    /// "128" or "127.9".
    case bpm
    /// "2" or "2/4"; the total isn't kept.
    case movement
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
        var text = text
        if let nul = text.firstIndex(of: "\u{0}") {
            if text[nul...].contains(where: { $0 != "\u{0}" }) {
                warnings.append(
                    MetadataWarning(
                        kind: .badText, offset: offset,
                        detail: "text holds a NUL; read up to it"))
            }
            text = String(text[..<nul])
        }
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
        case .grouping: grouping = grouping ?? text
        case .catalogNumber: catalogNumber = catalogNumber ?? text
        case .barcode: barcode = barcode ?? text
        case .key: key = key ?? text
        case .conductor: conductor = conductor ?? text
        case .lyricist: lyricist = lyricist ?? text
        case .publisher: publisher = publisher ?? text
        case .copyright: copyright = copyright ?? text
        case .encoder: encoder = encoder ?? text
        case .description: description = description ?? text
        case .discSubtitle: discSubtitle = discSubtitle ?? text
        case .work: work = work ?? text
        case .movementName: movementName = movementName ?? text
        case .originalDate: originalDate = originalDate ?? text
        case .bpm: bpm = bpm ?? beatsPerMinute(text, at: offset, &warnings)
        case .movement:
            movementNumber = movementNumber ?? numberPair(text, field, at: offset, &warnings).0
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
        var result = self
        let texts: [WritableKeyPath<TrackTags, String?>] = [
            \.title, \.artist, \.album, \.albumArtist, \.genre, \.date, \.composer, \.comment,
            \.grouping, \.catalogNumber, \.barcode, \.key, \.conductor, \.lyricist, \.publisher,
            \.copyright, \.encoder, \.description, \.discSubtitle, \.work, \.movementName,
            \.originalDate,
        ]
        for field in texts {
            result[keyPath: field] = self[keyPath: field] ?? other[keyPath: field]
        }
        let numbers: [WritableKeyPath<TrackTags, Int?>] = [
            \.trackNumber, \.trackTotal, \.discNumber, \.discTotal, \.bpm, \.movementNumber,
        ]
        for field in numbers {
            result[keyPath: field] = self[keyPath: field] ?? other[keyPath: field]
        }
        result.compilation = compilation || other.compilation
        return result
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
