import AppKit
import Discogs
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

extension TaggerModel.Source {
    var title: String {
        switch self {
        case .catalog: "Local Catalog"
        case .api: "Discogs API"
        case .both: "Both"
        }
    }
}

extension DiscogsField {
    /// As the Field Mapping and View Changes sheets name it, after YATE's Release screen: the
    /// track table's column's title where the two are the same tag.
    var title: String {
        switch self {
        case .releaseID: "Release ID"
        case .masterID: "Master ID"
        case .releaseURL: "Release URL"
        case .masterURL: "Master URL"
        case .album: TrackColumn.album.title
        case .albumArtist: TrackColumn.albumArtist.title
        case .albumArtistURL: "Album Artist URLs"
        case .label: "Labels"
        case .labelURL: "Label URLs"
        case .catalogNumber: TrackColumn.catalogNumber.title
        case .labelCatalogNumbers: "Labels' Catalog Numbers"
        case .barcode: TrackColumn.barcode.title
        case .country: "Release Country"
        case .date: "Released"
        case .genres: "Genres"
        case .styles: "Styles"
        case .media: "Release Formats"
        case .compilation: TrackColumn.compilation.title
        case .discCount: TrackColumn.discTotal.title
        case .title: TrackColumn.title.title
        case .artist: TrackColumn.artist.title
        case .artistList: "Artist List"
        case .artistNameVariations: "Name Variations"
        case .artistURL: "Artist URLs"
        case .trackNumber: TrackColumn.trackNumber.title
        case .trackCount: TrackColumn.trackTotal.title
        case .discNumber: TrackColumn.discNumber.title
        case .position: "Track Position"
        case .ordinalPosition: "Ordinal Position"
        case .discSubtitle: TrackColumn.discSubtitle.title
        case .composer: TrackColumn.composer.title
        case .conductor: TrackColumn.conductor.title
        case .lyricist: TrackColumn.lyricist.title
        case .remixer: "Remixers"
        case .producer: "Producers"
        case .involvedPeople: "Involved People"
        }
    }
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
    case score, artist, title, label, catalogNumber, country, year, format
    // Field Mapping.
    case discogsField, mode, targets, join, template

    var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(rawValue) }

    var title: String {
        switch self {
        case .album: TrackColumn.album.title
        case .files: "Files"
        case .review: "Review"
        case .number: TrackColumn.rowNumber.title
        case .fileTitle: TrackColumn.title.title
        case .fileTime, .releaseTime: TrackColumn.duration.title
        case .position: DiscogsField.position.title
        case .releaseTitle: "Release Track"
        case .state, .include: ""
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
        case .mode: "Mode"
        case .targets: "Tags"
        case .join: "Join"
        case .template: "Template"
        }
    }

    /// A column of `width` points with this title. A title's column shares the width the table
    /// gains; the rest keep theirs.
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

extension TrackComparison.State {
    /// The mark at the end of a row of the tracklists.
    var mark: String {
        switch self {
        case .matched: "✓"
        case .different: "≠"
        case .missing: "–"
        }
    }
}
