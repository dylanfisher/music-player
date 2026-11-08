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
    /// Each file's `DISCOGS_RELEASE_ORDINAL_POSITION`, which counts from 0, by file id.
    var ordinals: [Int64: Int]
}

/// The survey's albums that every track gives one release id, in name order, the ids taken
/// out of the tracks. With `titlesOnly` the label, catalog number, barcode, date, media and
/// country go too, as an
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
            barcode: titlesOnly ? nil : sorted.lazy.compactMap(\.barcode).first,
            date: titlesOnly ? nil : sorted.lazy.compactMap(\.date).first,
            media: titlesOnly ? nil : sorted.lazy.compactMap(\.media).first,
            country: titlesOnly
                ? nil
                : sorted.lazy.compactMap { file in
                    DiscogsKey.releaseCountry.lazy.compactMap { file.custom[$0] }.first
                }.first,
            tracks: tracks)
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

/// How the release chosen for an album stands to the one its files were tagged with.
enum Kinship: Equatable {
    case same
    /// Equal to it in every tag the matcher compares, which the owner decided on 2026-11-07
    /// counts as the same (ADR 0131).
    case twin
    /// Another release, or none.
    case other
}

/// What the tuning knows of one album's tagged release beside the match.
struct TuningOutcome: Equatable {
    var kinship: Kinship
    /// How the tagged release fits the files; nil when it isn't in the dump.
    var taggedFit: ReleaseFit?
    /// The tags' date or `MEDIA` is one the tagged release no longer has.
    var tagsOutdated = false
}

/// Matches the survey's matched albums with their ids hidden, against `catalog`, once with
/// their tags and once with titles only, and writes `report.txt` in `output`. Returns the
/// report.
func discogsTuning(survey lines: URL, catalog: URL, output: URL) async throws -> String {
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let report = output.appendingPathComponent(reportName, isDirectory: false)
    try requireCorpusWrite(report.path, roots: [output])
    let records = try loadRecords(lines)
    let releases = try Catalog(at: catalog)
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
        let outcomes = try zip(albums, matches).map { album, match -> TuningOutcome in
            guard let tagged = try releases.release(id: album.releaseID) else {
                return TuningOutcome(kinship: match.releaseID == album.releaseID ? .same : .other)
            }
            var kinship = Kinship.other
            if match.releaseID == album.releaseID {
                kinship = .same
            } else if let chosen = try match.releaseID.flatMap({ try releases.release(id: $0) }),
                chosen.isTwin(of: tagged)
            {
                kinship = .twin
            }
            return TuningOutcome(
                kinship: kinship, taggedFit: releaseFit(album.album, tagged),
                tagsOutdated: tagsOutdate(album.album, tagged))
        }
        out.append("")
        out += tuningLines(
            albums, matches, outcomes: outcomes, seconds: seconds,
            heading: titlesOnly
                ? "Titles only: ids, label, catalog number, barcode, date, media and country hidden"
                : "Tags: release ids hidden")
    }
    let text = out.joined(separator: "\n") + "\n"
    try requireCorpusWrite(report.path, roots: [output])
    try Data(text.utf8).write(to: report)
    return text
}

/// One run's section of the report: the bar as the owner decided it on 2026-11-07, then the
/// raw counts. A twin of the tagged release counts as it. Left out of the bar: albums whose
/// tagged release isn't in the dump or doesn't fit the files, and albums left Incomplete with
/// the tagged release or a twin chosen because the files are another count. Albums whose tags
/// name a date or format the tagged release no longer has are counted, and listed as known
/// misses when they miss.
func tuningLines(
    _ albums: [TuningAlbum], _ matches: [AlbumMatch], outcomes: [TuningOutcome],
    seconds: Double, heading: String
) -> [String] {
    var tiers: [MatchTier: Int] = [:]
    var same = 0
    var rawWrongExact = 0
    var sameOrTwin = 0
    var found = 0
    var ordinalsCompared = 0
    var ordinalsAgreeing = 0
    var notInDump: [String] = []
    var otherCount: [String] = []
    var otherTitles: [String] = []
    var keptOtherCount: [String] = []
    var twins: [String] = []
    var wrongExact: [String] = []
    var knownMisses: [String] = []
    var misses: [String] = []
    for ((album, match), outcome) in zip(zip(albums, matches), outcomes) {
        tiers[match.tier, default: 0] += 1
        let candidates = [match.releaseID].compactMap { $0 } + match.candidates.map(\.releaseID)
        if candidates.contains(album.releaseID) { found += 1 }
        let line =
            "\(album.name): \(match.tier.rawValue), chose \(match.releaseID.map(String.init) ?? "none"),"
            + " tagged \(album.releaseID), \(candidates.contains(album.releaseID) ? "a candidate" : "not found"),"
            + " \(candidates.count) candidates"
        let isFound = match.tier == .exact || match.tier == .likely
        let isRight = outcome.kinship != .other
        if isFound, outcome.kinship == .same { same += 1 }
        if match.tier == .exact, outcome.kinship != .same { rawWrongExact += 1 }
        if outcome.kinship == .twin { twins.append(line) }
        if outcome.kinship == .same {
            for (file, ordinal) in album.ordinals {
                guard let index = match.mapping[file] else { continue }
                ordinalsCompared += 1
                if index == ordinal { ordinalsAgreeing += 1 }
            }
        }
        switch outcome.taggedFit {
        case nil: notInDump.append(line)
        case .otherCount: otherCount.append(line)
        case .otherTitles: otherTitles.append(line)
        case .fits:
            if match.tier == .incomplete, isRight,
                match.releaseTrackCount != album.album.tracks.count
            {
                keptOtherCount.append(line)
            } else if isFound, isRight {
                sameOrTwin += 1
            } else {
                if match.tier == .exact { wrongExact.append(line) } else { misses.append(line) }
                if outcome.tagsOutdated { knownMisses.append(line) }
            }
        }
    }
    let total = max(albums.count, 1)
    let left = notInDump.count + otherCount.count + otherTitles.count + keptOtherCount.count
    let counted = max(albums.count - left, 1)
    func share(_ count: Int) -> String {
        String(format: "%d of %d (%.1f%%)", count, counted, 100 * Double(count) / Double(counted))
    }
    var out = ["== \(heading)", "\(albums.count) albums"]
    out.append(
        "-- The bar: at least 95% same or twin, at most 2% Exact with neither, of those counted")
    out.append("left out, the tagged release not in the dump: \(notInDump.count)")
    out.append("left out, the tagged release another count than the files: \(otherCount.count)")
    out.append("left out, the tagged release's titles not the files': \(otherTitles.count)")
    out.append(
        "left out, Incomplete with the tagged release or a twin, the files another count:"
            + " \(keptOtherCount.count)")
    out.append("counted: \(counted)")
    out.append("chosen a twin of the tagged release: \(twins.count)")
    out.append("Exact or Likely with the tagged release or a twin: \(share(sameOrTwin))")
    out.append("Exact with a release neither the tagged one nor a twin: \(share(wrongExact.count))")
    out.append(
        "known misses, the tags' date or MEDIA one the tagged release no longer has:"
            + " \(knownMisses.count)")
    out.append("-- Raw")
    for tier in MatchTier.allCases {
        out.append("\(tier.rawValue): \(tiers[tier] ?? 0)")
    }
    out.append(
        String(
            format: "Exact or Likely with the tagged release: %d (%.1f%%)", same,
            100 * Double(same) / Double(total)))
    out.append("Exact with another release: \(rawWrongExact)")
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
    for (title, lines) in [
        ("Exact with a release neither the tagged one nor a twin", wrongExact),
        ("Known misses: the tags' date or MEDIA one the tagged release no longer has", knownMisses),
        ("The rest counted and not Exact or Likely with the tagged release or a twin", misses),
        ("Twins chosen", twins),
        ("Left out: the tagged release not in the dump", notInDump),
        ("Left out: the tagged release another count than the files", otherCount),
        ("Left out: the tagged release's titles not the files'", otherTitles),
        ("Left out: Incomplete for another count", keptOtherCount),
    ] {
        out.append("-- \(title)")
        out += lines
    }
    return out
}
