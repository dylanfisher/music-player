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
/// the matcher, and what its files say the right answer is; or one whose tracks carry none,
/// with no answer known.
struct TuningAlbum {
    var name: String
    var album: DiscogsAlbum
    /// Nil for an album whose tracks carry no release id.
    var releaseID: Int?
    /// Each file's `DISCOGS_RELEASE_ORDINAL_POSITION`, which counts from 0, by file id.
    var ordinals: [Int64: Int]
}

/// The survey's albums that every track gives one release id, in name order, the ids taken
/// out of the tracks. With `titlesOnly` the label, catalog number, barcode, date, media and
/// country go too, as an album YATE never tagged would have none of them. With `untagged`,
/// instead, the albums no track gives a release id, with all their tags: the library the
/// tagger has still to match.
func tuningAlbums(_ records: [SurveyRecord], titlesOnly: Bool, untagged: Bool = false)
    -> [TuningAlbum]
{
    let albums = Dictionary(grouping: records.filter { $0.format != nil }, by: \.albumKey)
    var tuning: [TuningAlbum] = []
    var nextFileID: Int64 = 1
    for (key, files) in albums.sorted(by: { $0.key < $1.key }) {
        let ids = Set(files.map { $0.custom[DiscogsKey.releaseID] })
        let releaseID: Int?
        if untagged {
            guard ids == [nil] else { continue }
            releaseID = nil
        } else {
            guard ids.count == 1, let only = ids.first, let text = only, let id = Int(text)
            else { continue }
            releaseID = id
        }
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
    DiscogsKey.ordinalPosition, DiscogsKey.ordinalPositionTitled.uppercased(),
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
    /// Another release than the tagged one or a twin, of the tagged one's master.
    var sameMaster = false
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
    var albumLines: [String] = []
    for run in TuningRun.allCases {
        let albums = tuningAlbums(
            records, titlesOnly: run == .titlesOnly, untagged: run == .untagged)
        let started = Date()
        let matches = try await matchAlbums(
            albums.map(\.album), catalogAt: catalog, choosing: [:], skippingVideo: false
        ) {
            if $0.albumsDone % 100 == 0 || $0.albumsDone == $0.albumCount {
                FileHandle.standardError.write(
                    Data("matched \($0.albumsDone) of \($0.albumCount)\n".utf8))
            }
        }
        let seconds = Date().timeIntervalSince(started)
        let outcomes = try zip(albums, matches).map { album, match -> TuningOutcome? in
            guard let releaseID = album.releaseID else { return nil }
            guard let tagged = try releases.release(id: releaseID) else {
                return TuningOutcome(kinship: match.releaseID == releaseID ? .same : .other)
            }
            var kinship = Kinship.other
            var sameMaster = false
            if match.releaseID == releaseID {
                kinship = .same
            } else if let chosen = try match.releaseID.flatMap({ try releases.release(id: $0) }) {
                if chosen.isTwin(of: tagged) {
                    kinship = .twin
                } else {
                    sameMaster = chosen.masterID != nil && chosen.masterID == tagged.masterID
                }
            }
            return TuningOutcome(
                kinship: kinship, sameMaster: sameMaster,
                taggedFit: releaseFit(album.album, tagged),
                tagsOutdated: tagsOutdate(album.album, tagged))
        }
        out.append("")
        if run == .untagged {
            out += untaggedLines(albums, matches, seconds: seconds, heading: run.heading)
        } else {
            out += tuningLines(
                albums, matches, outcomes: outcomes.map { $0! }, seconds: seconds,
                heading: run.heading)
        }
        for ((album, match), outcome) in zip(zip(albums, matches), outcomes) {
            albumLines.append(albumLine(run, album, match, outcome))
        }
    }
    let text = out.joined(separator: "\n") + "\n"
    let perAlbum = output.appendingPathComponent(albumLinesName, isDirectory: false)
    try requireCorpusWrite(report.path, roots: [output])
    try requireCorpusWrite(perAlbum.path, roots: [output])
    try Data(text.utf8).write(to: report)
    try Data((albumLines.joined(separator: "\n") + "\n").utf8).write(to: perAlbum)
    return text
}

/// The file beside the report with one line per album and run, to compare two tunings by.
let albumLinesName = "albums.tsv"

/// One of the tuning's runs over the survey's albums.
enum TuningRun: String, CaseIterable {
    case tags, titlesOnly, untagged

    var heading: String {
        switch self {
        case .tags: "Tags: release ids hidden"
        case .titlesOnly:
            "Titles only: ids, label, catalog number, barcode, date, media and country hidden"
        case .untagged: "Untagged: the albums no track gives a release id, no answer known"
        }
    }
}

/// An album's line in `albumLinesName`: the run, the album, its tier, safety, confidence and
/// chosen release, how it was found, and, with an answer known, how the choice stands to it.
func albumLine(
    _ run: TuningRun, _ album: TuningAlbum, _ match: AlbumMatch, _ outcome: TuningOutcome?
) -> String {
    let verdict: String =
        switch outcome {
        case nil: "-"
        case let outcome? where outcome.kinship != .other: "right"
        case let outcome? where outcome.sameMaster: "same master"
        default: "wrong"
        }
    return [
        run.rawValue, album.name, match.tier.rawValue, match.safety.map { "\($0)" } ?? "-",
        match.confidence.map(String.init) ?? "-", match.releaseID.map(String.init) ?? "-",
        match.foundBy.map { "\($0)" } ?? "-", verdict,
    ].joined(separator: "\t")
}

/// The tabs Apply to All writes with the least review, by name, as the tagger lists them.
let applyTabs: [(String, @Sendable (AlbumMatch) -> Bool)] = [
    ("exact", { $0.tier == .exact }),
    ("safe", { $0.safety == .safe }),
    ("likely, not safe", { $0.tier == .likely && $0.safety == nil }),
]

/// The untagged run's section: the tiers and the safe tabs, with no answer to count against.
func untaggedLines(
    _ albums: [TuningAlbum], _ matches: [AlbumMatch], seconds: Double, heading: String
) -> [String] {
    var out = ["== \(heading)", "\(albums.count) albums"]
    for tier in MatchTier.allCases {
        out.append("\(tier.rawValue): \(matches.count { $0.tier == tier })")
    }
    out.append("safe: \(matches.count { $0.safety == .safe })")
    out.append(
        String(
            format: "%.1f s in all, %.1f ms an album", seconds,
            1000 * seconds / Double(max(albums.count, 1))))
    return out
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
        let taggedID = album.releaseID!
        if candidates.contains(taggedID) { found += 1 }
        let line =
            "\(album.name): \(match.tier.rawValue), chose \(match.releaseID.map(String.init) ?? "none"),"
            + " tagged \(taggedID), \(candidates.contains(taggedID) ? "a candidate" : "not found"),"
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
    out.append("-- Apply to All: right (the tagged release or a twin), same master, wrong")
    for (name, lists) in applyTabs {
        let listed = zip(matches, outcomes).filter { lists($0.0) }.map(\.1)
        let right = listed.count { $0.kinship != .other }
        let sameMaster = listed.count { $0.kinship == .other && $0.sameMaster }
        out.append(
            "\(name): \(listed.count), right \(right), same master \(sameMaster),"
                + " wrong \(listed.count - right - sameMaster)")
    }
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
