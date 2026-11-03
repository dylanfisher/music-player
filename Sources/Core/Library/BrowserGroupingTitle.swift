import Settings

extension BrowserGrouping {
    /// The column's menu item, in Swinsian's words.
    public var title: String {
        switch self {
        case .artistsAndAlbumArtists: "Artists / Album Artists"
        case .albumsByYear: "Albums by Year"
        case .audioQuality, .channels, .works: header
        case .originalReleaseDates: "Original Release Date"
        case .initialKeys: "Initial Key"
        default: header + "s"
        }
    }

    /// The column's header: one of what it lists, as the track table's column of the same tag
    /// calls it.
    public var header: String {
        switch self {
        case .artistsAndAlbumArtists: "Artist / Album Artist"
        case .audioQuality: "Audio Quality"
        case .folders: "Folder"
        case .artists: TrackColumn.artist.title
        case .albumArtists: TrackColumn.albumArtist.title
        case .albums, .albumsByYear: TrackColumn.album.title
        case .years: TrackColumn.year.title
        case .genres: TrackColumn.genre.title
        case .composers: TrackColumn.composer.title
        case .publishers: TrackColumn.publisher.title
        case .groupings: TrackColumn.grouping.title
        case .channels: TrackColumn.channels.title
        case .fileTypes: TrackColumn.fileType.title
        case .fileNames: TrackColumn.fileName.title
        case .conductors: TrackColumn.conductor.title
        case .comments: TrackColumn.comment.title
        case .descriptions: TrackColumn.description.title
        case .ratings: TrackColumn.rating.title
        case .lyricists: TrackColumn.lyricist.title
        case .works: TrackColumn.work.title
        case .originalReleaseDates: TrackColumn.originalDate.title
        case .initialKeys: TrackColumn.key.title
        }
    }

    /// The column's All row: "All (12 Genres)", "All (1 Genre)".
    public func allTitle(_ count: Int) -> String {
        guard count != 1 else { return "All (1 \(header))" }
        let plural =
            switch self {
            case .audioQuality: "Audio Qualities"
            case .channels: header
            default: header + "s"
            }
        return "All (\(count) \(plural))"
    }
}
