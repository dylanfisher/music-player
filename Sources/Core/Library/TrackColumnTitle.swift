import Settings

extension TrackColumn {
    /// The column's header, and a smart playlist field's title where the two read the same.
    public var title: String {
        switch self {
        case .title: "Title"
        case .artist: "Artist"
        case .album: "Album"
        case .albumArtist: "Album Artist"
        case .trackNumber: "#"
        case .discNumber: "Disc"
        case .year: "Year"
        case .genre: "Genre"
        case .duration: "Time"
        case .codec: "Format"
        case .sampleRate: "Sample Rate"
        case .bitDepth: "Bits"
        case .dateAdded: "Date Added"
        case .path: "Path"
        case .playCount: "Plays"
        case .skipCount: "Skips"
        case .lastPlayed: "Last Played"
        case .rating: "Rating"
        case .playlistOrder: "Order"
        }
    }
}
