/// How tall the track table's rows are.
public enum RowHeight: String, SettingChoice {
    case compact, regular, large

    public var title: String {
        switch self {
        case .compact: "Compact"
        case .regular: "Regular"
        case .large: "Large"
        }
    }
}
