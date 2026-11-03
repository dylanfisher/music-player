/// What a column of the browser lists, as Swinsian's column menu offers them, in its order.
public enum BrowserGrouping: String, SettingValue, CaseIterable {
    case artists, albumArtists, artistsAndAlbumArtists, albums, albumsByYear, years, genres,
        composers, publishers, groupings, audioQuality, channels, fileTypes, fileNames,
        conductors, comments, descriptions, folders, ratings, lyricists, works,
        originalReleaseDates, initialKeys

    public static var typeName: String {
        "a browser grouping (" + allCases.map(\.rawValue).joined(separator: ", ") + ")"
    }
    public static var kind: SettingKind { .windowState }
}
