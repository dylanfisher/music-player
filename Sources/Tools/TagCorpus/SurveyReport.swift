import Foundation
import Metadata

/// The Discogs survey's report on `records`, the files read under `folders` (ADR 0128): per
/// format, each custom key's files, albums and samples; how many albums carry a release id on
/// every track, some or none; and the conventions around it.
func surveyReport(_ records: [SurveyRecord], folders: [URL]) -> String {
    let read = records.filter { $0.format != nil }
    let failed = records.filter { $0.failure != nil }
    var out = ["Discogs survey of \(folders.map(\.path).joined(separator: ", "))"]
    out.append(
        "\(records.count) files, \(failed.count) unreadable,"
            + " \(Set(read.map(\.albumKey)).count) albums")

    let formats = Dictionary(grouping: read) { $0.format! }.sorted { $0.key < $1.key }
    out.append("\n== Files and albums by format")
    for (format, files) in formats {
        out.append("\(format): \(files.count) files, \(Set(files.map(\.albumKey)).count) albums")
    }

    out.append("\n== Albums by DISCOGS_RELEASE_ID on their tracks")
    out.append(releaseCoverageLine("all formats", read))
    for (format, files) in formats { out.append(releaseCoverageLine(format, files)) }

    for (format, files) in formats {
        out.append(
            "\n== Custom keys in \(format) files: files, albums, albums where every track has"
                + " the key with one value, samples")
        out += customKeyLines(files)
    }

    out.append(
        "\n== Keys with DISCOGS in their name, by spelling: files in each format")
    out += discogsKeySpellings(formats)

    let matched = read.filter { $0.custom[DiscogsKey.releaseID] != nil }
    out.append("\n== Conventions in the \(matched.count) files with DISCOGS_RELEASE_ID")
    out += conventionLines(matched)
    out.append("\n== Conventions in the \(read.count - matched.count) files without it")
    out += conventionLines(read.filter { $0.custom[DiscogsKey.releaseID] == nil })

    out.append("\n== Unreadable files (\(failed.count))")
    out += failed.map { $0.failure! }
    return out.joined(separator: "\n") + "\n"
}

/// Whether each album's tracks carry a release id, as 51.3 counts them.
enum ReleaseCoverage: String, CaseIterable {
    case oneID = "every track, one id"
    case severalIDs = "every track, several ids"
    case some = "some tracks"
    case none = "no track"

    init(_ tracks: [SurveyRecord]) {
        let ids = tracks.map { $0.custom[DiscogsKey.releaseID] }
        let present = ids.compactMap { $0 }
        if present.isEmpty {
            self = .none
        } else if present.count < ids.count {
            self = .some
        } else {
            self = Set(present).count == 1 ? .oneID : .severalIDs
        }
    }
}

private func releaseCoverageLine(_ name: String, _ files: [SurveyRecord]) -> String {
    let albums = Dictionary(grouping: files, by: \.albumKey).values.map(ReleaseCoverage.init)
    let counts = ReleaseCoverage.allCases.map { coverage in
        "\(coverage.rawValue) \(albums.filter { $0 == coverage }.count)"
    }
    return "\(name): \(albums.count) albums; " + counts.joined(separator: ", ")
}

private func customKeyLines(_ files: [SurveyRecord]) -> [String] {
    let albums = Dictionary(grouping: files, by: \.albumKey)
    let keys = Set(files.flatMap(\.custom.keys))
    let rows = keys.map { key in
        let carrying = files.filter { $0.custom[key] != nil }
        let albumsWithKey = albums.values.filter { $0.contains { $0.custom[key] != nil } }
        let constant = albumsWithKey.filter { tracks in
            let values = tracks.map { $0.custom[key] }
            return !values.contains(nil) && Set(values).count == 1
        }
        return (
            key: key, files: carrying.count, albums: albumsWithKey.count,
            constant: constant.count, samples: samples(carrying.compactMap { $0.custom[key] })
        )
    }
    return rows.sorted { ($0.files, $1.key) > ($1.files, $0.key) }.map {
        "\($0.key): \($0.files) files, \($0.albums) albums, \($0.constant) constant; \($0.samples)"
    }
}

/// Up to `limit` distinct values, in the order first seen, each cut to 100 characters.
private func samples(_ values: [String], limit: Int = 3) -> String {
    var seen: [String] = []
    for value in values where !seen.contains(value) {
        seen.append(value)
        if seen.count == limit { break }
    }
    return seen.map { "\"\($0.count > 100 ? String($0.prefix(100)) + "…" : $0)\"" }
        .joined(separator: " | ")
}

/// `GENRE` as YATE's template writes it for the owner: the genre, " - ", then the styles,
/// joined with ", ". Discogs genre names hold commas themselves ("Folk, World, & Country"), so
/// the genre is everything before the first " - ".
struct GenreLayout: Equatable {
    var genre: String
    /// The text after each " - ": the styles, more than once when the template repeated them.
    var styleParts: [String]

    init?(_ text: String) {
        let parts = text.components(separatedBy: " - ")
        guard parts.count >= 2 else { return nil }
        genre = parts[0]
        styleParts = Array(parts.dropFirst())
    }

    var styles: String { styleParts[0] }

    /// The styles written more than once, " - " between them: a template error.
    var isRepeated: Bool { styleParts.count >= 2 && Set(styleParts).count == 1 }
}

/// Counts of each convention among `files`, with samples.
private func conventionLines(_ files: [SurveyRecord]) -> [String] {
    var lines: [String] = []
    func tally(_ name: String, _ matching: [SurveyRecord], _ value: (SurveyRecord) -> String?) {
        lines.append(
            "\(name): \(matching.count) of \(files.count); "
                + samples(matching.compactMap(value), limit: 5))
    }
    func histogram(_ name: String, _ values: [String], top: Int = 15) {
        let counts = Dictionary(grouping: values) { $0 }.mapValues(\.count)
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(top)
        lines.append(
            "\(name), the \(top) most common: "
                + counts.map { "\"\($0.key)\" \($0.value)" }.joined(separator: ", "))
    }
    let genres = files.compactMap { file in file.genre.map { (file, $0) } }
    let layouts = genres.compactMap { file, genre in GenreLayout(genre).map { (file, $0) } }
    tally("GENRE set", genres.map(\.0), \.genre)
    tally("GENRE as \"genre - styles\"", layouts.map(\.0), \.genre)
    tally(
        "  of those, the styles repeated after another \" - \"",
        layouts.filter { $0.1.isRepeated }.map(\.0), \.genre)
    tally(
        "  of those, more than one \" - \" and not a repeat",
        layouts.filter { $0.1.styleParts.count > 1 && !$0.1.isRepeated }.map(\.0), \.genre)
    tally(
        "  of those, no styles after \" - \"", layouts.filter { $0.1.styles.isEmpty }.map(\.0),
        \.genre)
    histogram("  their genre before \" - \"", layouts.map(\.1.genre))
    tally(
        "GENRE without \" - \"", genres.filter { GenreLayout($0.1) == nil }.map(\.0), \.genre)

    tally("MOOD set", files.filter { $0.mood != nil }, \.mood)
    tally(
        "MOOD equal to GENRE's styles",
        layouts.filter { $0.0.mood == $0.1.styles }.map(\.0), \.mood)
    tally(
        "MOOD equal to GENRE's repeated styles, \" - \" between them",
        layouts.filter { $0.1.isRepeated && $0.0.mood == $0.1.styleParts.joined(separator: " - ") }
            .map(\.0), \.mood)
    tally(
        "MOOD set and neither",
        files.filter { file in
            guard let mood = file.mood else { return false }
            let layout = file.genre.flatMap(GenreLayout.init)
            return mood != layout?.styles && mood != layout?.styleParts.joined(separator: " - ")
        }, { "\($0.mood!) (GENRE \($0.genre ?? "none"))" })

    tally("GROUPING set", files.filter { $0.grouping != nil }, \.grouping)
    tally(
        "GROUPING equal to LABEL", files.filter { $0.grouping != nil && $0.grouping == $0.label },
        \.grouping)
    tally(
        "GROUPING set and not LABEL",
        files.filter { $0.grouping != nil && $0.grouping != $0.label },
        { "\($0.grouping!) (LABEL \($0.label ?? "none"))" })
    tally(
        "GROUPING equal to LABEL's first label, before \" & \"",
        files.filter {
            $0.grouping != nil && $0.grouping != $0.label && $0.grouping == firstLabel($0)
        },
        { "\($0.grouping!) (LABEL \($0.label!))" })
    tally("LABEL set", files.filter { $0.label != nil }, \.label)
    tally(
        "LABEL with \" & \" between labels", files.filter { $0.label?.contains(" & ") == true },
        \.label)
    tally("CATALOGNUMBER set", files.filter { $0.catalogNumber != nil }, \.catalogNumber)

    let catalogKey = "DISCOGS_CATALOG_NUMBER"
    tally(
        "\(catalogKey) as \"LABEL: CATALOGNUMBER\"",
        files.filter { file in
            file.label != nil && file.catalogNumber != nil
                && file.custom[catalogKey] == "\(file.label!): \(file.catalogNumber!)"
        }, { $0.custom[catalogKey] })
    tally(
        "\(catalogKey) as \"LABEL's first label: CATALOGNUMBER\" where LABEL has several",
        files.filter { file in
            file.label?.contains(" & ") == true && file.catalogNumber != nil
                && file.custom[catalogKey] == "\(firstLabel(file)!): \(file.catalogNumber!)"
        }, { "\($0.custom[catalogKey]!) (LABEL \($0.label!))" })
    tally(
        "\(catalogKey) set and neither",
        files.filter { file in
            file.custom[catalogKey] != nil
                && file.custom[catalogKey] != "\(file.label ?? ""): \(file.catalogNumber ?? "")"
                && file.custom[catalogKey]
                    != "\(firstLabel(file) ?? ""): \(file.catalogNumber ?? "")"
        },
        {
            "\($0.custom[catalogKey]!) (LABEL \($0.label ?? "none"), CATALOGNUMBER \($0.catalogNumber ?? "none"))"
        })

    tally(
        "\(DiscogsKey.releaseID) all digits",
        files.filter { $0.custom[DiscogsKey.releaseID].map(isDigits) == true },
        { $0.custom[DiscogsKey.releaseID] })
    tally(
        "\(DiscogsKey.releaseID) set and not all digits",
        files.filter { $0.custom[DiscogsKey.releaseID].map(isDigits) == false },
        { $0.custom[DiscogsKey.releaseID] })
    tally(
        "\(DiscogsKey.masterID) as \"m\" and digits",
        files.filter { $0.custom[DiscogsKey.masterID].map(isMasterID) == true },
        { $0.custom[DiscogsKey.masterID] })
    tally(
        "\(DiscogsKey.masterID) set and not that",
        files.filter { $0.custom[DiscogsKey.masterID].map(isMasterID) == false },
        { $0.custom[DiscogsKey.masterID] })

    tally(
        "ARTIST or ALBUMARTIST with a \"(2)\" suffix",
        files.filter { [$0.artist, $0.albumArtist].contains { $0.map(hasNumberSuffix) == true } },
        { [$0.artist, $0.albumArtist].compactMap { $0 }.joined(separator: " / ") })
    let artistList = "DISCOGS_ARTIST_LIST"
    tally(
        "\(artistList) equal to ARTIST",
        files.filter { $0.custom[artistList] != nil && $0.custom[artistList] == $0.artist },
        { $0.custom[artistList] })
    tally(
        "\(artistList) set and not ARTIST",
        files.filter { $0.custom[artistList] != nil && $0.custom[artistList] != $0.artist },
        { "\($0.custom[artistList]!) (ARTIST \($0.artist ?? "none"))" })

    let anvKey = "DISCOGS_ANV_LIST"
    let anvPairs = files.flatMap { file in
        (file.custom[anvKey] ?? "").components(separatedBy: yateValueSeparator).compactMap {
            pair -> (file: SurveyRecord, canonical: String, anv: String)? in
            let sides = pair.components(separatedBy: "=")
            return sides.count == 2 ? (file, sides[0], sides[1]) : nil
        }
    }
    func artists(_ file: SurveyRecord) -> String {
        [file.artist, file.albumArtist].compactMap { $0 }.joined(separator: " / ")
    }
    lines.append("\(anvKey) pairs, canonical=ANV: \(anvPairs.count)")
    tally(
        "  of those, ARTIST or ALBUMARTIST holds the canonical name, any (2) dropped",
        anvPairs.filter { artists($0.file).contains(withoutNumberSuffix($0.canonical)) }.map(
            \.file),
        { $0.custom[anvKey] })
    tally(
        "  of those, it holds the ANV and not the canonical name",
        anvPairs.filter {
            !artists($0.file).contains(withoutNumberSuffix($0.canonical))
                && artists($0.file).contains($0.anv)
        }.map(\.file), { "\($0.custom[anvKey]!) (\(artists($0)))" })
    tally(
        "  of those, the canonical name has a (2) suffix",
        anvPairs.filter { hasNumberSuffix($0.canonical) }.map(\.file),
        { "\($0.custom[anvKey]!) (\(artists($0)))" })
    tally(
        "Custom values holding \"\(yateValueSeparator)\" between values",
        files.filter { $0.custom.values.contains { $0.contains(yateValueSeparator) } },
        { file in
            file.custom.first { $0.value.contains(yateValueSeparator) }.map {
                "\($0.key)=\($0.value)"
            }
        })
    tally(
        "ALBUM ending in a year in brackets",
        files.filter { $0.album.map(endsInBracketedYear) == true }, \.album)
    tally("MEDIA set", files.filter { $0.media != nil }, \.media)
    histogram("MEDIA values", files.compactMap(\.media), top: 10)
    for (shape, count) in Dictionary(grouping: files.compactMap(\.date), by: dateShape)
        .mapValues(\.count).sorted(by: { $0.key < $1.key })
    {
        lines.append("DATE shaped \(shape): \(count) of \(files.count)")
    }
    return lines
}

/// What YATE puts between the values of one key, as in `DISCOGS_ARTIST_LIST`.
private let yateValueSeparator = ";;;"

/// The first of the labels LABEL joins with " & ".
private func firstLabel(_ file: SurveyRecord) -> String? {
    file.label?.components(separatedBy: " & ").first
}

/// Each key with DISCOGS in its name, with its files in each format, spellings that differ
/// only in "_" against " " side by side.
private func discogsKeySpellings(_ formats: [(key: String, value: [SurveyRecord])]) -> [String] {
    var counts: [String: [String: Int]] = [:]
    for (format, files) in formats {
        for file in files {
            for key in file.custom.keys where key.contains("DISCOGS") {
                counts[key, default: [:]][format, default: 0] += 1
            }
        }
    }
    func folded(_ key: String) -> String {
        key.replacingOccurrences(of: "_", with: "").replacingOccurrences(of: " ", with: "")
    }
    return counts.keys.sorted { (folded($0), $0) < (folded($1), $1) }.map { key in
        key + ": "
            + counts[key]!.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }
            .joined(separator: ", ")
    }
}

private func isDigits(_ text: String) -> Bool {
    !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isNumber }
}

private func isMasterID(_ text: String) -> Bool {
    text.first == "m" && isDigits(String(text.dropFirst()))
}

/// "Name (2)": Discogs's suffix for the second artist of a name.
func hasNumberSuffix(_ name: String) -> Bool {
    guard name.hasSuffix(")"), let open = name.lastIndex(of: "(") else { return false }
    let inner = name[name.index(after: open)..<name.index(before: name.endIndex)]
    return open > name.startIndex && name[name.index(before: open)] == " "
        && isDigits(String(inner))
}

/// `name` without a trailing " (2)".
private func withoutNumberSuffix(_ name: String) -> String {
    guard hasNumberSuffix(name), let open = name.lastIndex(of: "(") else { return name }
    return String(name[..<name.index(before: open)])
}

private func endsInBracketedYear(_ title: String) -> Bool {
    let tail = Array(title.suffix(6))
    guard tail.count == 6, ["(", "["].contains(tail[0]), [")", "]"].contains(tail[5]) else {
        return false
    }
    return isDigits(String(tail[1...4]))
}

/// "YYYY", "YYYY-MM-DD" and so on: each digit as 9, so dates of one shape group together.
private func dateShape(_ date: String) -> String {
    String(date.map { $0.isASCII && $0.isNumber ? "9" : $0 })
}
