import AppKit
import Discogs
import DisplayText
import Library
import Settings

// The tagger window's names for what it shows, each defined once.

extension MatchTier {
    /// A tab's title, before its count.
    var title: String {
        switch self {
        case .exact: "Exact"
        case .likely: "Likely"
        case .incomplete: "Incomplete"
        case .noCandidate: "No Candidate"
        case .matched: "Matched"
        }
    }
}

extension TaggerModel.Scope {
    var title: String {
        switch self {
        case .library: "Whole Library"
        case .selection: "Albums Selected in the Library"
        case .unmatched: "Unmatched Albums"
        }
    }
}

extension CatalogStatus {
    /// The line the window shows of a catalog in place: "Catalog from the 2026-11-01 dump ·
    /// 3.1 GB".
    var shown: String {
        "Catalog from the \(dumpDay) dump · \(fileSizeText(sizeBytes))"
    }

    /// Its tooltip: where the catalog is and when it was imported.
    var detail: String {
        let imported = DateFormatter.localizedString(
            from: importedAt, dateStyle: .medium, timeStyle: .short)
        return "\((url.path as NSString).abbreviatingWithTildeInPath)\nImported \(imported)"
    }

    /// The dump's date, which Discogs writes as 20261101, as 2026-11-01.
    private var dumpDay: String {
        guard dumpDate.count == 8, dumpDate.allSatisfy(\.isNumber) else { return dumpDate }
        let digits = Array(dumpDate)
        return "\(String(digits[0..<4]))-\(String(digits[4..<6]))-\(String(digits[6..<8]))"
    }
}

extension NotExactReason {
    /// "2 files have no track on the release": one of the reasons under the release's title.
    var text: String {
        switch self {
        case .filesWithoutTrack(let files):
            "\(count(files, "file")) \(files == 1 ? "has" : "have") no track on the release"
        case .tracksWithoutFile(let count):
            "\(tracks(count)) of the release \(count == 1 ? "has" : "have") no file"
        case .countDiffers(let files, let tracks):
            "\(count(files, "file")), the release has \(DisplayText.tracks(tracks))"
        case .outOfOrder(let files):
            "\(count(files, "file")) \(files == 1 ? "is" : "are") out of the release's order"
        case .titlesDiffer(let titles):
            "\(count(titles, "file title")) "
                + (titles == 1 ? "differs from its track's" : "differ from their tracks'")
        case .durationsDiffer(let lengths, let seconds, let fraction):
            "\(count(lengths, "file length")) \(lengths == 1 ? "is" : "are") off by more than"
                + " \(number(Int(seconds))) s or \(number(Int((fraction * 100).rounded())))%"
        case .releaseIDsDiffer: "its files carry different release IDs, or only some carry one"
        case .tiedAfterTieBreak: "other releases fit as well"
        case .foundByTitleOnly: "found by title only"
        }
    }
}

/// Open on Discogs: release `id`'s page, through `open`, the browser unless a test stands in.
@MainActor
func openOnDiscogs(_ id: Int, through open: (URL) -> Void = { NSWorkspace.shared.open($0) }) {
    open(discogsPage(id))
}

/// A column of the tagger's tables: its identifier is the case's name.
enum TaggerColumn: String {
    // The album list.
    case album, files, review
    // The tracklists side by side.
    case number, fileTitle, fileTime, position, releaseTitle, releaseTime, state
    // View Changes.
    case include, fileName, field, tag, current, written
    // Other Releases.
    case score, artist, title, label, catalogNumber, country, year, format, tracks
    // Field Mapping.
    case discogsField, mode, targets, join, template

    var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(rawValue) }

    var title: String {
        switch self {
        case .album: TrackColumn.album.title
        case .files: "Files"
        case .review: "Review"
        case .number: TrackColumn.rowNumber.title
        case .fileTitle, .releaseTitle: TrackColumn.title.title
        case .fileTime, .releaseTime: TrackColumn.duration.title
        case .position: DiscogsField.position.title
        case .state: "Match"
        case .include: ""
        case .fileName: TrackColumn.fileName.title
        case .field, .discogsField: "Discogs Field"
        case .tag: "Tag"
        case .current: "Now"
        case .written: "To Write"
        case .score: "Fit"
        case .artist: TrackColumn.artist.title
        case .title: TrackColumn.title.title
        case .label: DiscogsField.label.title
        case .catalogNumber: TrackColumn.catalogNumber.title
        case .country: DiscogsField.country.title
        case .year: TrackColumn.year.title
        case .format: DiscogsField.media.title
        case .tracks: "Tracks"
        case .mode: "Mode"
        case .targets: "Tags"
        case .join: "Join"
        case .template: "Template"
        }
    }

    /// A column of `width` points with this title. A title's column shares the width the table
    /// gains; the rest keep theirs.
    @MainActor
    func column(width: CGFloat) -> NSTableColumn {
        let column = NSTableColumn(identifier: identifier)
        column.title = title
        column.width = width
        let flexible: Set<TaggerColumn> = [
            .album, .fileTitle, .releaseTitle, .current, .written, .title, .targets, .template,
        ]
        column.resizingMask =
            flexible.contains(self) ? [.autoresizingMask, .userResizingMask] : .userResizingMask
        return column
    }
}

/// A table for a tagger sheet or pane, with `columns` of their widths, in a bordered scroll
/// view.
@MainActor
func taggerTable(
    _ table: NSTableView, _ columns: [(TaggerColumn, CGFloat)],
    source: some NSTableViewDataSource & NSTableViewDelegate
) -> NSScrollView {
    for (column, width) in columns { table.addTableColumn(column.column(width: width)) }
    table.dataSource = source
    table.delegate = source
    table.usesAlternatingRowBackgroundColors = true
    table.style = .fullWidth
    table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    let scroll = NSScrollView()
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    return scroll
}

extension DiscogsFieldRule.Mode {
    static let shown: [DiscogsFieldRule.Mode] = [.replace, .fillEmpty, .off]

    var title: String {
        switch self {
        case .replace: "Replace Tag"
        case .fillEmpty: "Fill Empty Tag"
        case .off: "Off"
        }
    }
}

extension TrackComparison {
    /// The mark at the end of a row of the tracklists, with the word that says what it means.
    var stateText: String {
        switch state {
        case .matched: "✓ Same"
        case .different: "≠ Differs"
        case .missing: fileID == nil ? "– No file" : "– No track"
        }
    }

    /// The mark's tooltip.
    var stateTip: String {
        switch state {
        case .matched: "The file's title and length fit the track's"
        case .different: "The file's title or length differs from the track's"
        case .missing:
            fileID == nil ? "No file is on this track" : "This file is on none of the tracks"
        }
    }
}
