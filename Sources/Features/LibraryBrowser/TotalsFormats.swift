import Settings

/// The status bar's totals as their templates write them: the line while nothing is selected
/// (`appearance.totalsFormat`), and one for each choice a click on the totals cycles through
/// (ADR 0188).
public struct TotalsFormats: Equatable, Sendable {
    public var nothingSelected: TotalsTemplate
    public var listAndSelection: TotalsTemplate
    public var list: TotalsTemplate
    public var selection: TotalsTemplate

    public init(
        nothingSelected: TotalsTemplate, listAndSelection: TotalsTemplate, list: TotalsTemplate,
        selection: TotalsTemplate
    ) {
        self.nothingSelected = nothingSelected
        self.listAndSelection = listAndSelection
        self.list = list
        self.selection = selection
    }

    /// The settings' defaults: the list's track count, size and length, with the selection's
    /// after them in parentheses, alone, or not at all, as the click chose.
    static let defaults = TotalsFormats(
        nothingSelected: AppSettings().totalsFormat.defaultValue,
        listAndSelection: AppSettings().totalsListAndSelectionFormat.defaultValue,
        list: AppSettings().totalsListFormat.defaultValue,
        selection: AppSettings().totalsSelectionFormat.defaultValue)

    /// The template for `shown`, or the nothing-selected line's while nothing is.
    func template(_ shown: StatusTotals, selected: Bool) -> TotalsTemplate {
        guard selected else { return nothingSelected }
        return switch shown {
        case .listAndSelection: listAndSelection
        case .list: list
        case .selection: selection
        }
    }
}
