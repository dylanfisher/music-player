/// How the track table's Album Art column draws art: a thumbnail in each row, or the album's
/// art as wide as the column, spanning the album's rows.
public enum ArtSize: String, SettingChoice {
    case thumbnail, fullWidth

    public var title: String {
        switch self {
        case .thumbnail: "Thumbnail"
        case .fullWidth: "Full Width"
        }
    }
}
