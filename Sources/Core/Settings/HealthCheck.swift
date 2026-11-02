/// One group of the library health report (ADR 0034). The raw value names it in a saved
/// source, so renaming a case drops a saved selection of it.
public enum HealthCheck: String, CaseIterable, Sendable {
    /// Files the scanner couldn't read.
    case unreadable
    /// Files read with a field read in part or dropped.
    case warnings
    /// Playlist entries whose file left the index.
    case missingEntries
    /// The same album, album artist, disc and track number.
    case sameNumber
    /// The same title and artist, within a second of the same length.
    case sameTitle
    /// Albums with a track number missing below the highest, on any disc.
    case trackGaps
    /// One album title in one folder under more than one album artist.
    case severalAlbumArtists
    case mixedSampleRates
    case noArt
    case noAlbum
    case noAlbumArtist
    /// Paths with stats whose file left and that no scan matched with a new path (ADR 0026).
    case lostStats
    /// Paths the user removed from the library, which scans skip until restored (ADR 0048).
    case removed
}
