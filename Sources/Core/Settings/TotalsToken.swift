/// Text filled from the totals of the list and of the selection: what the status bar's totals
/// settings hold, `appearance.totalsFormat` and one for each choice a click cycles through
/// (ADR 0188).
public typealias TotalsTemplate = TokenTemplate<TotalsToken>

extension TokenTemplate where Token == TotalsToken {
    private static var listText: String { "{tracks}, {size}, {duration}" }
    private static var selectionText: String {
        "{selectedTracks} selected, {selectedSize}, {selectedDuration}"
    }

    /// "1,204 tracks, 5.1 GiB, 3 days 2 hours": the line while nothing is selected, whichever
    /// totals the click chose.
    public static var nothingSelected: TotalsTemplate { TotalsTemplate(listText) }

    /// The line for `shown` while tracks are selected: "1,204 tracks, 5.1 GiB, 3 days 2 hours
    /// (3 tracks selected, 10.2 MiB, 12 minutes)" for both.
    public static func shown(_ shown: StatusTotals) -> TotalsTemplate {
        switch shown {
        case .listAndSelection: TotalsTemplate("\(listText) (\(selectionText))")
        case .list: TotalsTemplate(listText)
        case .selection: TotalsTemplate(selectionText)
        }
    }
}

/// A total of the list the track table shows, or of its selection, that a `TotalsTemplate`
/// names in braces, as `{tracks}`.
public enum TotalsToken: String, TemplateToken {
    case tracks, size, duration, albums
    case selectedTracks, selectedSize, selectedDuration, selectedAlbums
    case missing

    public static var example: String { TotalsTemplate.nothingSelected.template }

    public var help: String {
        switch self {
        case .tracks: "How many tracks the list shows, as 1,204 tracks"
        case .size: "Their files' size, as 5.1 GiB"
        case .duration: "Their length, as 3 days 2 hours"
        case .albums: "How many albums they're on, as 98 albums"
        case .selectedTracks: "How many tracks are selected; empty while none is"
        case .selectedSize: "The selected files' size"
        case .selectedDuration: "The selected tracks' length"
        case .selectedAlbums: "How many albums the selected tracks are on"
        case .missing:
            "How many of a playlist's tracks aren't in the library, as 2 tracks; empty when"
                + " none is missing. Without it the bar adds \"· 2 tracks not in the library\""
        }
    }
}
