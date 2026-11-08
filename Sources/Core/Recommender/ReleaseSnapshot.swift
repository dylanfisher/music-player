/// What a job downloads: a Discogs release as the player's local catalog has it, built on a Mac
/// with the catalog, since the service has none. Titles go as Discogs spells them; the service
/// folds them itself.
public struct ReleaseSnapshot: Equatable, Sendable, Encodable {
    /// One track of a tracklist, as the files of an album hold it.
    public struct Track: Equatable, Sendable, Encodable {
        /// Not empty, and unique in its list; the service reports each file's track by it.
        public var position: String
        public var title: String
        public var seconds: Int?

        private enum CodingKeys: String, CodingKey {
            case position, title, seconds
        }

        public init(position: String, title: String, seconds: Int?) {
            self.position = position
            self.title = title
            self.seconds = seconds
        }

        /// `seconds` goes as `null` when there's none, not left out.
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(position, forKey: .position)
            try container.encode(title, forKey: .title)
            try container.encode(seconds, forKey: .seconds)
        }
    }

    /// Most tracks a tracklist may have.
    public static let trackCap = 500

    public var releaseID: Int
    /// `Various` for a compilation.
    public var artist: String
    public var title: String
    public var year: Int?
    /// One or two: the ways the release's tracklist can be an album's files, the first the
    /// one the player prefers.
    public var tracklists: [[Track]]

    private enum CodingKeys: String, CodingKey {
        case releaseID = "release_id"
        case artist, title, year, tracklists
    }

    public init(releaseID: Int, artist: String, title: String, year: Int?, tracklists: [[Track]]) {
        self.releaseID = releaseID
        self.artist = artist
        self.title = title
        self.year = year
        self.tracklists = tracklists
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(releaseID, forKey: .releaseID)
        try container.encode(artist, forKey: .artist)
        try container.encode(title, forKey: .title)
        try container.encode(year, forKey: .year)
        try container.encode(tracklists, forKey: .tracklists)
    }
}
