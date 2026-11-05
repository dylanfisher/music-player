/// A column of the track table. Every column can be shown and moved, and every one but the row
/// number and Now Playing sorted by; Library holds what each sorts by and its title, which the
/// smart playlist editor shares. The header's menu lists them in this order.
public enum TrackColumn: String, Codable, CaseIterable, Sendable {
    case rowNumber, nowPlaying, art, title, artist, album, albumArtist, composer, conductor,
        lyricist, grouping,
        work, movementNumber, movementName, genre, year, originalDate, trackNumber, trackTotal,
        trackOfTotal, discNumber, discTotal, discOfTotal, discSubtitle, compilation, duration, bpm,
        key, codec, fileType, bitRate, sampleRate, bitDepth, channels, size, fileName, path,
        dateAdded, dateCreated, dateModified, playCount, skipCount, lastPlayed, rating, loved,
        publisher, catalogNumber, barcode, copyright, encoder, comment, description,
        playlistOrder

    /// The row number is the row's place in the list as sorted, and Now Playing marks one row,
    /// so sorting by either means nothing.
    public var isSortable: Bool { self != .rowNumber && self != .nowPlaying }
}
