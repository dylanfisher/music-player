/// An album as the Discogs matcher compares it with releases (ADR 0131): what its tags say
/// about the release, and its tracks in order.
public struct DiscogsAlbum: Equatable, Sendable {
    public struct Track: Equatable, Sendable {
        public var fileID: Int64
        public var title: String?
        public var seconds: Double
        public var discNumber: Int?
        public var trackNumber: Int?
        /// `DISCOGS_RELEASE_ID`, as written.
        public var releaseID: String?

        public init(
            fileID: Int64, title: String?, seconds: Double, discNumber: Int? = nil,
            trackNumber: Int? = nil, releaseID: String? = nil
        ) {
            self.fileID = fileID
            self.title = title
            self.seconds = seconds
            self.discNumber = discNumber
            self.trackNumber = trackNumber
            self.releaseID = releaseID
        }
    }

    public var id: Int64
    public var title: String
    /// The album artist, else the track artist; nil for a compilation without one.
    public var artist: String?
    /// `LABEL`, which can name several labels joined with " & " (ADR 0128).
    public var label: String?
    public var catalogNumber: String?
    public var barcode: String?
    /// `DATE`, which YATE writes as the release's date as Discogs has it.
    public var date: String?
    /// `MEDIA`, which YATE writes as the release's format and its descriptions:
    /// "Vinyl (LP,Album)", "File (FLAC,Album)", "CD" (ADR 0128).
    public var media: String?
    /// The release's country, from YATE's keys (`DiscogsKey.releaseCountry`).
    public var country: String?
    /// In disc and track order.
    public var tracks: [Track]

    public init(
        id: Int64, title: String, artist: String?, label: String? = nil,
        catalogNumber: String? = nil, barcode: String? = nil, date: String? = nil,
        media: String? = nil, country: String? = nil, tracks: [Track]
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.label = label
        self.catalogNumber = catalogNumber
        self.barcode = barcode
        self.date = date
        self.media = media
        self.country = country
        self.tracks = tracks
    }
}

extension LibraryIndex {
    /// Every album with its tracks, read from the index alone, so nothing is read from the
    /// files. An album's label, catalog number, barcode, date, media and country are its first
    /// track's that has one. Tracks without an album aren't in an album to match.
    package func discogsAlbums() throws -> [DiscogsAlbum] {
        let rows = try database.prepare(
            """
            SELECT t.album_id, a.title, ar.name, t.file_id, t.title, t.length_frames,
                t.sample_rate_hz, t.disc_number, t.track_number, t.discogs_release_id,
                t.publisher, t.catalog_number, t.barcode, t.date, t.media, t.country
            FROM tracks t JOIN albums a ON a.id = t.album_id JOIN files f ON f.id = t.file_id
            LEFT JOIN artists ar ON ar.id = a.artist_id
            ORDER BY t.album_id, t.disc_number IS NULL, t.disc_number, t.track_number IS NULL,
                t.track_number, f.path
            """
        ).map { row in
            let rateHz = try row.int(6)
            let album = DiscogsAlbum(
                id: try row.int64(0), title: try row.text(1), artist: row.optionalText(2),
                label: row.optionalText(10), catalogNumber: row.optionalText(11),
                barcode: row.optionalText(12), date: row.optionalText(13),
                media: row.optionalText(14), country: row.optionalText(15), tracks: [])
            let track = DiscogsAlbum.Track(
                fileID: try row.int64(3), title: row.optionalText(4),
                seconds: rateHz > 0 ? Double(try row.int(5)) / Double(rateHz) : 0,
                discNumber: row.optionalInt(7), trackNumber: row.optionalInt(8),
                releaseID: row.optionalText(9))
            return (album, track)
        }
        var albums: [DiscogsAlbum] = []
        for (album, track) in rows {
            if albums.last?.id != album.id { albums.append(album) }
            var last = albums.removeLast()
            last.label = last.label ?? album.label
            last.catalogNumber = last.catalogNumber ?? album.catalogNumber
            last.barcode = last.barcode ?? album.barcode
            last.date = last.date ?? album.date
            last.media = last.media ?? album.media
            last.country = last.country ?? album.country
            last.tracks.append(track)
            albums.append(last)
        }
        return albums
    }
}
