/// Whether the Discogs tagger writes a release's primary image as the files' cover (ADR 0140):
/// never, only to files with no cover, or over any cover. A setting of its own, not a field
/// of the mapping, since the dumps have no images and every saved mapping would need it.
public enum DiscogsArtworkMode: String, SettingChoice {
    case off, fillEmpty, replace

    public var title: String {
        switch self {
        case .off: "Off"
        case .fillEmpty: "Fill Empty"
        case .replace: "Replace All"
        }
    }
}
