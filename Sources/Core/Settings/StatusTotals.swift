/// Which totals the status bar shows: those of the whole list, the selection's after them, or
/// the selection's alone. A click on them moves to the next.
public enum StatusTotals: String, SettingChoice {
    case listAndSelection, list, selection

    public var title: String {
        switch self {
        case .listAndSelection: "List and Selection"
        case .list: "List Only"
        case .selection: "Selection Only"
        }
    }

    /// The choice a click on the totals moves to.
    public var next: StatusTotals {
        switch self {
        case .listAndSelection: .list
        case .list: .selection
        case .selection: .listAndSelection
        }
    }
}
