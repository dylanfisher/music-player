import Settings

extension TrackColumn {
    /// The column's header, and a smart playlist field's title where the two read the same.
    public var title: String {
        switch self {
        case .rowNumber: "#"
        case .nowPlaying: "Now Playing"
        case .art: "Art"
        case .title: "Title"
        case .artist: "Artist"
        case .album: "Album"
        case .albumArtist: "Album Artist"
        case .composer: "Composer"
        case .conductor: "Conductor"
        case .lyricist: "Lyricist"
        case .grouping: "Grouping"
        case .work: "Work"
        case .movementNumber: "Movement Number"
        case .movementName: "Movement"
        case .genre: "Genre"
        case .mood: "Mood"
        case .year: "Year"
        case .originalDate: "Original Date"
        case .trackNumber: "Track"
        case .trackTotal: "Track Total"
        case .trackOfTotal: "Track of Total"
        case .discNumber: "Disc"
        case .discTotal: "Disc Total"
        case .discOfTotal: "Disc of Total"
        case .discSubtitle: "Disc Subtitle"
        case .compilation: "Compilation"
        case .duration: "Time"
        case .bpm: "BPM"
        case .key: "Key"
        case .codec: "Format"
        case .fileType: "File Type"
        case .bitRate: "Bit Rate"
        case .sampleRate: "Sample Rate"
        case .bitDepth: "Bits"
        case .channels: "Channels"
        case .cutoff: "Cutoff"
        case .effectiveBits: "Effective Bits"
        case .dynamicRange: "Dynamic Range"
        case .truePeak: "True Peak"
        case .size: "Size"
        case .fileName: "File Name"
        case .path: "Path"
        case .dateAdded: "Date Added"
        case .dateCreated: "Date Created"
        case .dateModified: "Date Modified"
        case .playCount: "Plays"
        case .skipCount: "Skips"
        case .lastPlayed: "Last Played"
        case .rating: "Rating"
        case .loved: "Loved"
        case .publisher: "Publisher"
        case .catalogNumber: "Catalog #"
        case .barcode: "Barcode"
        case .discogsReleaseID: "Discogs Release ID"
        case .discogsMasterID: "Discogs Master ID"
        case .copyright: "Copyright"
        case .encoder: "Encoder"
        case .comment: "Comment"
        case .description: "Description"
        case .playlistOrder: "Order"
        }
    }

    /// The column's header: `title`, shortened where the full one is wider than the column
    /// needs. The header menu, the tooltip and the smart playlist fields keep `title`.
    public var headerTitle: String {
        switch self {
        case .trackOfTotal: "Track No."
        case .discOfTotal: "Disc No."
        default: title
        }
    }
}
