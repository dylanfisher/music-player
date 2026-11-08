/// Where the Discogs tagger looks releases up: the local catalog, the Discogs API, or both,
/// the catalog first and the API for the albums it can't place (ADR 0139).
public enum DiscogsSource: String, SettingChoice {
    case catalog, api, both

    public var title: String {
        switch self {
        case .catalog: "Local Catalog"
        case .api: "Discogs API"
        case .both: "Both"
        }
    }
}
