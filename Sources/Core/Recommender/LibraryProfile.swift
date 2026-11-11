import Foundation

/// The library as music-recommender reads it, the body of its profile (`docs/api.md` there,
/// section Profile): each album with its tracks' lengths, catalog numbers, barcodes, Discogs
/// release id, plays and loved tracks. No ratings yet (ADR 0198).
public struct LibraryProfile: Equatable, Sendable, Encodable {
    public struct Album: Equatable, Sendable, Encodable {
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

        private enum CodingKeys: String, CodingKey {
            case artist, title, durations, plays, loved
            case trackCount = "track_count"
            case catalogNumbers = "catalog_numbers"
            case barcodes
            case discogsReleaseID = "discogs_release_id"
        }

        public init(
            artist: String, title: String, durations: [Int], catalogNumbers: [String],
            barcodes: [String], discogsReleaseID: Int?, plays: Int, loved: Int
        ) {
            self.artist = artist
            self.title = title
            self.durations = durations
            self.catalogNumbers = catalogNumbers
            self.barcodes = barcodes
            self.discogsReleaseID = discogsReleaseID
            self.plays = plays
            self.loved = loved
        }

        /// `track_count` is the durations' count, and `discogs_release_id` goes as `null`
        /// when there's none, not left out.
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(artist, forKey: .artist)
            try container.encode(title, forKey: .title)
            try container.encode(durations.count, forKey: .trackCount)
            try container.encode(durations, forKey: .durations)
            try container.encode(catalogNumbers, forKey: .catalogNumbers)
            try container.encode(barcodes, forKey: .barcodes)
            try container.encode(discogsReleaseID, forKey: .discogsReleaseID)
            try container.encode(plays, forKey: .plays)
            try container.encode(loved, forKey: .loved)
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
