/// The dumps' element names the parser looks at; any other is nil and passed over.
enum DumpElement: String {
    // Records.
    case label, artist, master, release
    // Fields.
    case id, name, anv, join, role, tracks, title, country, released, genre, style, year
    case description, position, duration, identifier, format, track
    case masterID = "master_id"
    case mainRelease = "main_release"
    // Lists.
    case artists, extraartists, labels, formats, descriptions, genres, styles, tracklist
    case namevariations
    case subTracks = "sub_tracks"
    // Subtrees nothing is kept from.
    case videos, notes, companies, series, contactinfo, profile, urls, sublabels, realname
    case aliases, members, groups
    case parentLabel
    case dataQuality = "data_quality"

    /// The element each record of `kind` is.
    init(record kind: DumpKind) {
        self =
            switch kind {
            case .labels: .label
            case .artists: .artist
            case .masters: .master
            case .releases: .release
            }
    }

    /// Subtrees of a `kind` record that hold nothing the catalog keeps.
    static func skipped(in kind: DumpKind) -> Set<DumpElement> {
        switch kind {
        case .labels: [.contactinfo, .profile, .urls, .sublabels, .parentLabel, .dataQuality]
        case .artists: [.profile, .realname, .urls, .aliases, .members, .groups, .dataQuality]
        case .masters: [.videos, .notes, .dataQuality]
        case .releases: [.videos, .notes, .companies, .series, .dataQuality]
        }
    }
}

/// The dumps' attribute names the parser reads.
enum DumpAttribute: String {
    case id, name, catno, qty, text, type, value
    case isMainRelease = "is_main_release"
}
