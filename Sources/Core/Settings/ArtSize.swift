/// How the track table's Album Art column draws an album's art across the album's rows: scaled
/// down to fit them, or always as wide as the column and cut off at the album's last row.
public enum ArtSize: String, SettingChoice {
    case fit, fullWidth

    public var title: String {
        switch self {
        case .fit: "Scaled to Fit"
        case .fullWidth: "Full Width"
        }
    }
}
