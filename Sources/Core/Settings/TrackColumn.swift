/// A column of the track table. Every column can be shown, moved and sorted by; Library holds what
/// each sorts by, and LibraryBrowser its title.
public enum TrackColumn: String, Codable, CaseIterable, Sendable {
    case title, artist, album, albumArtist, trackNumber, discNumber, year, genre, duration, codec,
        sampleRate, bitDepth, dateAdded, path
}
