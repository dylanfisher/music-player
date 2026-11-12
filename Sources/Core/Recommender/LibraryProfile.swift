import Foundation

/// The library as music-recommender reads it, the body of its profile (`docs/api.md` there,
/// section Profile): each album with its key, its tracks' lengths, catalog numbers, barcodes,
/// Discogs release id, plays, loved tracks, last play and skips. No ratings yet (ADR 0198).
public struct LibraryProfile: Equatable, Sendable, Encodable {
    public struct Album: Equatable, Sendable, Encodable {
        /// The player's name for the album, which Rediscover's replies give back (ADR 0206).
        public var key: String
        public var artist: String
        public var title: String
        /// Each track's length in whole seconds, in disc and track order.
        public var durations: [Int]
        /// The distinct values the tracks' tags hold, in track order.
        public var catalogNumbers: [String]
        public var barcodes: [String]
        public var discogsReleaseID: Int?
        /// The tracks' plays, summed.
        public var plays: Int
        /// How many of the tracks are loved.
        public var loved: Int
        /// The latest play of a track recorded in the player, in Unix seconds; never an
        /// imported Last Played (ADR 0105).
        public var lastPlayed: Int?
        /// The tracks' skips, summed.
        public var skips: Int

        private enum CodingKeys: String, CodingKey {
            case key, artist, title, durations, plays, loved, skips
            case lastPlayed = "last_played"
            case trackCount = "track_count"
            case catalogNumbers = "catalog_numbers"
            case barcodes
            case discogsReleaseID = "discogs_release_id"
        }

        public init(
            key: String, artist: String, title: String, durations: [Int],
            catalogNumbers: [String], barcodes: [String], discogsReleaseID: Int?, plays: Int,
            loved: Int, lastPlayed: Int?, skips: Int
        ) {
            self.key = key
            self.artist = artist
            self.title = title
            self.durations = durations
            self.catalogNumbers = catalogNumbers
            self.barcodes = barcodes
            self.discogsReleaseID = discogsReleaseID
            self.plays = plays
            self.loved = loved
            self.lastPlayed = lastPlayed
            self.skips = skips
        }

        /// `track_count` is the durations' count, and `discogs_release_id` and `last_played`
        /// go as `null` when there's none, not left out.
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(key, forKey: .key)
            try container.encode(artist, forKey: .artist)
            try container.encode(title, forKey: .title)
            try container.encode(durations.count, forKey: .trackCount)
            try container.encode(durations, forKey: .durations)
            try container.encode(catalogNumbers, forKey: .catalogNumbers)
            try container.encode(barcodes, forKey: .barcodes)
            try container.encode(discogsReleaseID, forKey: .discogsReleaseID)
            try container.encode(plays, forKey: .plays)
            try container.encode(loved, forKey: .loved)
            try container.encode(lastPlayed, forKey: .lastPlayed)
            try container.encode(skips, forKey: .skips)
        }
    }

    public var albums: [Album]

    public init(albums: [Album]) { self.albums = albums }

    /// The JSON the service reads, encoded as its requests are.
    public func json() -> Data {
        do {
            return try requestEncoder.encode(self)
        } catch {
            preconditionFailure("a profile always encodes: \(error)")
        }
    }
}
