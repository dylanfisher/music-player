import Foundation
import StrictKeys

/// A day's albums of the library worth playing again, from `POST /v1/rediscover` (`docs/api.md`
/// there, section Rediscover; ADR 0206). Every field is always there, an absent value `null`; a
/// `kind` this player doesn't know fails the reply, naming the field, so it is shown rather
/// than skipped.
package struct RediscoverDay: Equatable, Sendable, Decodable {
    package typealias Named = RecommendationPage.Named

    /// What the day was drawn from.
    package struct Facts: Equatable, Sendable, Decodable {
        /// The `day` asked, `YYYY-MM-DD`.
        package var day: String
        /// When the scores the draw is from were computed, in Unix seconds.
        package var computedAt: Int
        /// The profile's albums before the draw and the not-now marks.
        package var albumsConsidered: Int

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case day
            case computedAt = "computed_at"
            case albumsConsidered = "albums_considered"
        }
    }

    /// Why an album is among the day's. The fields its `kind` doesn't use are nil or empty.
    package struct Reason: Equatable, Sendable, Decodable {
        package enum Kind: String, Equatable, Sendable, Decodable {
            case neverPlayed = "never_played"
            case notPlayedSince = "not_played_since"
            case loved, community, artist, credit, label, related
        }

        package var kind: Kind
        /// For showing, not for parsing.
        package var words: String
        /// The profile keys of the albums played in the last 30 days it shares this with, the
        /// most played first; empty but for `artist`, `credit`, `label` and `related`.
        package var keys: [String]
        package var artist: Named?
        package var role: String?
        package var label: Named?

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case kind, words, keys, artist, role, label
        }
    }

    package struct Album: Equatable, Sendable, Decodable {
        /// The service's name for the album, the same from every Mac: what Not Now takes.
        package var id: String
        /// The profile's key, which names the album in this player's index.
        package var key: String
        package var artist: String
        package var title: String
        package var releaseID: Int?
        package var year: Int?
        package var label: Named?
        package var styles: [Named]
        package var plays: Int
        package var skips: Int
        package var lastPlayed: Int?
        /// From 0 to 1, 1 for the profile's best scored album.
        package var score: Double
        package var community: CommunityValues?
        /// Up to 3, strongest first.
        package var reasons: [Reason]

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case id, key, artist, title
            case releaseID = "release_id"
            case year, label, styles, plays, skips
            case lastPlayed = "last_played"
            case score, community, reasons
        }
    }

    /// Day's albums that share something.
    package struct Thread: Equatable, Sendable, Decodable {
        package enum Kind: String, Equatable, Sendable, Decodable {
            case artist, credit, label, related, styles
        }

        package var kind: Kind
        /// For showing, not for parsing.
        package var words: String
        /// The `id`s of its albums, 2 or more, in the order of the day's albums.
        package var ids: [String]
        package var artist: Named?
        package var label: Named?

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case kind, words, ids, artist, label
        }
    }

    package var facts: Facts
    /// At most 60, best first.
    package var albums: [Album]
    /// At most 8, strongest first.
    package var threads: [Thread]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case ok
        case facts = "rediscover"
        case albums, threads
    }
}

extension RediscoverDay {
    package init(from decoder: any Decoder) throws {
        let container = try strictContainer(decoder, CodingKeys.self)
        facts = try container.decode(Facts.self, forKey: .facts)
        albums = try container.decode([Album].self, forKey: .albums)
        threads = try container.decode([Thread].self, forKey: .threads)
    }

    /// `date`'s day in `timeZone` as the route's `day` takes it, `YYYY-MM-DD` in the Gregorian
    /// calendar whatever calendar the Mac shows.
    package static func day(of date: Date, in timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else {
            preconditionFailure("a Gregorian date always has a year, month and day")
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}

extension RediscoverDay.Facts {
    package init(from decoder: any Decoder) throws {
        let container = try strictContainer(decoder, CodingKeys.self)
        day = try container.decode(String.self, forKey: .day)
        computedAt = try container.decode(Int.self, forKey: .computedAt)
        albumsConsidered = try container.decode(Int.self, forKey: .albumsConsidered)
    }
}

extension RediscoverDay.Reason {
    package init(from decoder: any Decoder) throws {
        let container = try strictContainer(decoder, CodingKeys.self)
        kind = try container.decode(Kind.self, forKey: .kind)
        words = try container.decode(String.self, forKey: .words)
        keys = try container.decode([String].self, forKey: .keys)
        artist = try container.decode(RediscoverDay.Named?.self, forKey: .artist)
        role = try container.decode(String?.self, forKey: .role)
        label = try container.decode(RediscoverDay.Named?.self, forKey: .label)
    }
}

extension RediscoverDay.Album {
    package init(from decoder: any Decoder) throws {
        let container = try strictContainer(decoder, CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        key = try container.decode(String.self, forKey: .key)
        artist = try container.decode(String.self, forKey: .artist)
        title = try container.decode(String.self, forKey: .title)
        releaseID = try container.decode(Int?.self, forKey: .releaseID)
        year = try container.decode(Int?.self, forKey: .year)
        label = try container.decode(RediscoverDay.Named?.self, forKey: .label)
        styles = try container.decode([RediscoverDay.Named].self, forKey: .styles)
        plays = try container.decode(Int.self, forKey: .plays)
        skips = try container.decode(Int.self, forKey: .skips)
        lastPlayed = try container.decode(Int?.self, forKey: .lastPlayed)
        score = try container.decode(Double.self, forKey: .score)
        community = try container.decode(CommunityValues?.self, forKey: .community)
        reasons = try container.decode([RediscoverDay.Reason].self, forKey: .reasons)
    }
}

extension RediscoverDay.Thread {
    package init(from decoder: any Decoder) throws {
        let container = try strictContainer(decoder, CodingKeys.self)
        kind = try container.decode(Kind.self, forKey: .kind)
        words = try container.decode(String.self, forKey: .words)
        ids = try container.decode([String].self, forKey: .ids)
        artist = try container.decode(RediscoverDay.Named?.self, forKey: .artist)
        label = try container.decode(RediscoverDay.Named?.self, forKey: .label)
    }
}
