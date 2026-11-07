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

/// `GENRE` as YATE's template writes it for the owner: the first genre, " - ", then the styles.
struct GenreLayout: Equatable {
    var genre: String
    var styles: [String]

    init?(_ text: String) {
        guard let range = text.range(of: " - ") else { return nil }
        genre = String(text[..<range.lowerBound])
        styles = text[range.upperBound...].components(separatedBy: ", ")
    }

    /// The styles written twice over, a template error.
    var isDoubled: Bool {
        styles.count >= 2 && styles.count.isMultiple(of: 2)
            && Array(styles.prefix(styles.count / 2)) == Array(styles.suffix(styles.count / 2))
    }

    /// The styles once each.
    var distinctStyles: [String] { isDoubled ? Array(styles.prefix(styles.count / 2)) : styles }
}

/// Counts of each convention among `files`, with samples.
private func conventionLines(_ files: [SurveyRecord]) -> [String] {
    var lines: [String] = []
    func tally(_ name: String, _ matching: [SurveyRecord], _ value: (SurveyRecord) -> String?) {
        lines.append(
            "\(name): \(matching.count) of \(files.count); "
                + samples(matching.compactMap(value), limit: 5))
    }
    let genres = files.compactMap { file in file.genre.map { (file, $0) } }
    let layouts = genres.compactMap { file, genre in GenreLayout(genre).map { (file, $0) } }
    tally("GENRE set", genres.map(\.0), \.genre)
    tally("GENRE as \"genre - styles\"", layouts.map(\.0), \.genre)
    tally(
        "  of those, more than one genre before \" - \"",
        layouts.filter { $0.1.genre.contains(", ") }.map(\.0), \.genre)
    tally("  of those, the styles doubled", layouts.filter { $0.1.isDoubled }.map(\.0), \.genre)
    tally(
        "GENRE without \" - \"", genres.filter { GenreLayout($0.1) == nil }.map(\.0), \.genre)

    tally("MOOD set", files.filter { $0.mood != nil }, \.mood)
    tally(
        "MOOD equal to GENRE's styles, once each",
        layouts.filter { $0.0.mood == $0.1.distinctStyles.joined(separator: ", ") }.map(\.0),
        \.mood)
    tally(
        "MOOD equal to GENRE's styles as written, doubled",
        layouts.filter { $0.1.isDoubled && $0.0.mood == $0.1.styles.joined(separator: ", ") }
            .map(\.0), \.mood)
    tally(
        "MOOD set and neither",
        files.filter { file in
            guard let mood = file.mood else { return false }
            let layout = file.genre.flatMap(GenreLayout.init)
            return mood != layout?.distinctStyles.joined(separator: ", ")
                && mood != layout?.styles.joined(separator: ", ")
        }, { "\($0.mood!) (GENRE \($0.genre ?? "none"))" })

    tally("GROUPING set", files.filter { $0.grouping != nil }, \.grouping)
    tally(
        "GROUPING equal to LABEL", files.filter { $0.grouping != nil && $0.grouping == $0.label },
        \.grouping)
    tally(
        "GROUPING set and not LABEL",
        files.filter { $0.grouping != nil && $0.grouping != $0.label },
        { "\($0.grouping!) (LABEL \($0.label ?? "none"))" })
    tally("LABEL set", files.filter { $0.label != nil }, \.label)
    tally("LABEL with \", \"", files.filter { $0.label?.contains(", ") == true }, \.label)
    tally("CATALOGNUMBER set", files.filter { $0.catalogNumber != nil }, \.catalogNumber)

    let catalogKey = "DISCOGS_CATALOG_NUMBER"
    tally(
        "\(catalogKey) as \"LABEL: CATALOGNUMBER\"",
        files.filter { file in
            file.label != nil && file.catalogNumber != nil
                && file.custom[catalogKey] == "\(file.label!): \(file.catalogNumber!)"
        }, { $0.custom[catalogKey] })
    tally(
        "\(catalogKey) set and not that",
        files.filter { file in
            file.custom[catalogKey] != nil
                && file.custom[catalogKey] != "\(file.label ?? ""): \(file.catalogNumber ?? "")"
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

    tally(
        "ALBUM ending in a year in brackets",
        files.filter { $0.album.map(endsInBracketedYear) == true }, \.album)
    tally("MEDIA set", files.filter { $0.media != nil }, \.media)
    for (shape, count) in Dictionary(grouping: files.compactMap(\.date), by: dateShape)
        .mapValues(\.count).sorted(by: { $0.key < $1.key })
    {
        lines.append("DATE shaped \(shape): \(count) of \(files.count)")
    }
    return lines
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
