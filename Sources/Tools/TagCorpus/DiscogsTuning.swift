import Discogs
import Foundation
import Library
import Metadata

/// The tuning's folder: `.build/discogs-tuning` under the current directory, the only place
/// the tuning writes (ADR 0131).
func tuningFolder() -> URL {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent(".build/discogs-tuning", isDirectory: true)
}

/// An album of the survey whose tracks all carry one release id, with that id hidden from
/// the matcher, and what its files say the right answer is.
struct TuningAlbum {
    var name: String
    var album: DiscogsAlbum
    var releaseID: Int
    /// Each file's `DISCOGS_RELEASE_ORDINAL_POSITION`, by file id, where it has one.
    var ordinals: [Int64: Int]
}

/// The survey's albums that every track gives one release id, in name order, the ids taken
/// out of the tracks. With `titlesOnly` the label, catalog number and barcode go too, as an
/// album YATE never tagged would have none of them.
func tuningAlbums(_ records: [SurveyRecord], titlesOnly: Bool) -> [TuningAlbum] {
    let albums = Dictionary(grouping: records.filter { $0.format != nil }, by: \.albumKey)
    var tuning: [TuningAlbum] = []
    var nextFileID: Int64 = 1
    for (key, files) in albums.sorted(by: { $0.key < $1.key }) {
        let ids = Set(files.map { $0.custom[DiscogsKey.releaseID] })
        guard ids.count == 1, let only = ids.first, let text = only, let releaseID = Int(text)
        else { continue }
        let sorted = files.sorted {
            ($0.discNumber ?? Int.max, $0.trackNumber ?? Int.max, $0.path)
                < ($1.discNumber ?? Int.max, $1.trackNumber ?? Int.max, $1.path)
        }
        var ordinals: [Int64: Int] = [:]
        var tracks: [DiscogsAlbum.Track] = []
        for file in sorted {
            let fileID = nextFileID
            nextFileID += 1
            if let ordinal = ordinalKeys.lazy.compactMap({ file.custom[$0].flatMap { Int($0) } })
                .first
            {
                ordinals[fileID] = ordinal
            }
            tracks.append(
                DiscogsAlbum.Track(
                    fileID: fileID, title: file.title, seconds: file.seconds,
                    discNumber: file.discNumber, trackNumber: file.trackNumber))
        }
        let first = sorted[0]
        let album = DiscogsAlbum(
            id: Int64(tuning.count),
            title: first.album ?? (first.path as NSString)
                .deletingLastPathComponent.components(separatedBy: "/").last ?? "",
            artist: first.albumArtist ?? (first.compilation ? nil : first.artist),
            label: titlesOnly ? nil : sorted.lazy.compactMap(\.label).first,
            catalogNumber: titlesOnly ? nil : sorted.lazy.compactMap(\.catalogNumber).first,
            barcode: titlesOnly ? nil : sorted.lazy.compactMap(\.barcode).first, tracks: tracks)
        tuning.append(
            TuningAlbum(
                name: key.replacingOccurrences(of: "\u{1F}", with: " / "), album: album,
                releaseID: releaseID, ordinals: ordinals))
    }
    return tuning
}

/// YATE's spellings of a track's place in the release's tracklist, uppercased (ADR 0128).
private let ordinalKeys = [
    "DISCOGS_RELEASE_ORDINAL_POSITION", "DISCOGS RELEASE ORDINAL POSITION",
]

/// Matches the survey's matched albums with their ids hidden, against `catalog`, once with
/// their tags and once with titles only, and writes `report.txt` in `output`. Returns the
/// report.
func discogsTuning(survey lines: URL, catalog: URL, output: URL) async throws -> String {
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let report = output.appendingPathComponent("report.txt", isDirectory: false)
    try requireCorpusWrite(report.path, roots: [output])
    let records = try loadRecords(lines)
    var out = ["Discogs matcher tuning: \(lines.path) against \(catalog.path)"]
    for titlesOnly in [false, true] {
        let albums = tuningAlbums(records, titlesOnly: titlesOnly)
        let started = Date()
        let matches = try await matchAlbums(albums.map(\.album), catalogAt: catalog) {
            if $0.albumsDone % 100 == 0 || $0.albumsDone == $0.albumCount {
                FileHandle.standardError.write(
                    Data("matched \($0.albumsDone) of \($0.albumCount)\n".utf8))
            }
        }
        let seconds = Date().timeIntervalSince(started)
        out.append("")
        out += tuningLines(
            albums, matches, seconds: seconds,
            heading: titlesOnly
                ? "Titles only: ids, label, catalog number and barcode hidden"
                : "Tags: release ids hidden")
    }
    let text = out.joined(separator: "\n") + "\n"
    try requireCorpusWrite(report.path, roots: [output])
    try Data(text.utf8).write(to: report)
    return text
}

/// One run's section of the report.
func tuningLines(
    _ albums: [TuningAlbum], _ matches: [AlbumMatch], seconds: Double, heading: String
) -> [String] {
    var out = ["== \(heading)", "\(albums.count) albums"]
    var tiers: [MatchTier: Int] = [:]
    var same = 0
    var wrongExact: [String] = []
    var misses: [String] = []
    var found = 0
    var ordinalsCompared = 0
    var ordinalsAgreeing = 0
    for (album, match) in zip(albums, matches) {
        tiers[match.tier, default: 0] += 1
        let isSame = match.releaseID == album.releaseID
        let candidates = [match.releaseID].compactMap { $0 } + match.candidates.map(\.releaseID)
        if candidates.contains(album.releaseID) { found += 1 }
        if isSame, match.tier == .exact || match.tier == .likely {
            same += 1
        } else {
            let line =
                "\(album.name): \(match.tier.rawValue), chose \(match.releaseID.map(String.init) ?? "none"),"
                + " tagged \(album.releaseID), \(candidates.contains(album.releaseID) ? "a candidate" : "not found"),"
                + " \(candidates.count) candidates"
            if match.tier == .exact { wrongExact.append(line) } else { misses.append(line) }
        }
        if isSame {
            for (file, ordinal) in album.ordinals {
                guard let index = match.mapping[file] else { continue }
                ordinalsCompared += 1
                if index + 1 == ordinal { ordinalsAgreeing += 1 }
            }
        }
    }
    let total = max(albums.count, 1)
    for tier in MatchTier.allCases {
        out.append("\(tier.rawValue): \(tiers[tier] ?? 0)")
    }
    out.append(
        String(
            format: "Exact or Likely with the tagged release: %d (%.1f%%)", same,
            100 * Double(same) / Double(total)))
    out.append("Exact with another release: \(wrongExact.count)")
    out.append(
        String(
            format: "tagged release among the candidates: %d (%.1f%%)", found,
            100 * Double(found) / Double(total)))
    out.append(
        "files mapped to the track their ordinal position names, of those compared:"
            + " \(ordinalsAgreeing) of \(ordinalsCompared)")
    out.append(
        String(
            format: "%.1f s in all, %.1f ms an album", seconds, 1000 * seconds / Double(total)))
    out.append("-- Exact with another release")
    out += wrongExact
    out.append("-- The rest not Exact or Likely with the tagged release")
    out += misses
    return out
}
