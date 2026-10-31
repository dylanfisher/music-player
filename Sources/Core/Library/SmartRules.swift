import Foundation
import SQLite
import Settings

/// A smart playlist's rules: which tracks it holds, as the rule editor sets them. Stored as JSON
/// in `playlists.rules` and compiled to SQL each time the playlist is listed, so it follows the
/// library and the stats as they change.
public struct SmartRules: Codable, Equatable, Sendable {
    public enum Match: String, Codable, CaseIterable, Sendable {
        /// Every rule holds.
        case all
        /// At least one rule holds.
        case any
    }

    public var match: Match
    /// No rules matches every track.
    public var rules: [SmartRule]
    public var limit: SmartLimit?

    public init(match: Match, rules: [SmartRule], limit: SmartLimit? = nil) {
        self.match = match
        self.rules = rules
        self.limit = limit
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case match, rules, limit
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(decoder, CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        match = try container.decode(Match.self, forKey: .match)
        rules = try container.decode([SmartRule].self, forKey: .rules)
        limit = try container.decodeIfPresent(SmartLimit.self, forKey: .limit)
    }

    /// The rules as stored.
    public func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    /// Reads stored rules, failing on any key, field or value this build doesn't know.
    public init(json: String) throws {
        self = try JSONDecoder().decode(SmartRules.self, from: Data(json.utf8))
    }
}

/// One rule: a field, how it compares, and what with.
public struct SmartRule: Codable, Equatable, Sendable {
    public var field: SmartField
    public var comparison: SmartComparison
    public var value: SmartValue

    public init(_ field: SmartField, _ comparison: SmartComparison, _ value: SmartValue) {
        self.field = field
        self.comparison = comparison
        self.value = value
    }

    /// Why the rule can't be compiled, or nil when it can: the comparison must suit the field,
    /// and the value must be text for a text field and a whole number otherwise.
    public var problem: String? {
        guard SmartComparison.comparisons(for: field.kind).contains(comparison) else {
            return "\(field.rawValue) can't be compared with \(comparison.rawValue)"
        }
        switch (field.kind, value) {
        case (.text, .text): return nil
        case (.number, .number(let number)), (.date, .number(let number)):
            guard number >= 0 else { return "\(field.rawValue) can't be negative" }
            if field == .rating, number > SmartField.maxRating {
                return "a rating is 0 to \(SmartField.maxRating) stars, not \(number)"
            }
            return nil
        case (.text, .number): return "\(field.rawValue) takes text, not a number"
        case (.number, .text), (.date, .text):
            return "\(field.rawValue) takes a whole number, not text"
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case field, comparison, value
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(decoder, CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        field = try container.decode(SmartField.self, forKey: .field)
        comparison = try container.decode(SmartComparison.self, forKey: .comparison)
        value = try container.decode(SmartValue.self, forKey: .value)
        if let problem {
            throw DecodingError.dataCorruptedError(
                forKey: .value, in: container, debugDescription: problem)
        }
    }
}

/// What a rule compares with: text for a text field, a whole number for a number, or a number of
/// days for a date.
public enum SmartValue: Codable, Equatable, Sendable {
    case text(String)
    case number(Int)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int.self) {
            self = .number(number)
        } else {
            self = .text(try container.decode(String.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text): try container.encode(text)
        case .number(let number): try container.encode(number)
        }
    }
}

public enum SmartField: String, Codable, CaseIterable, Sendable {
    case title, artist, album, albumArtist, genre, composer, comment, codec, path
    case year, trackNumber, discNumber, duration, sampleRate, bitDepth, playCount, skipCount,
        rating
    case dateAdded, lastPlayed

    public enum Kind: Sendable {
        case text
        /// Durations in seconds, sample rates in hertz, ratings in stars.
        case number
        /// Compared in days before now.
        case date
    }

    /// Ratings are whole stars, 1 to this; 0 is unrated.
    public static let maxRating = 5

    public var kind: Kind {
        switch self {
        case .title, .artist, .album, .albumArtist, .genre, .composer, .comment, .codec, .path:
            .text
        case .year, .trackNumber, .discNumber, .duration, .sampleRate, .bitDepth, .playCount,
            .skipCount, .rating:
            .number
        case .dateAdded, .lastPlayed: .date
        }
    }

    /// The SQL the rule compares, over the tables `TrackColumn.expression` names plus `p` (plays)
    /// and `r` (ratings). The names and titles are the folded sort columns, which a folded value
    /// matches whatever its case and accents.
    var expression: String {
        switch self {
        case .composer: "t.composer"
        case .comment: "t.comment"
        case .title: TrackColumn.title.expression
        case .artist: TrackColumn.artist.expression
        case .album: TrackColumn.album.expression
        case .albumArtist: TrackColumn.albumArtist.expression
        case .genre: TrackColumn.genre.expression
        case .codec: TrackColumn.codec.expression
        case .path: TrackColumn.path.expression
        case .year: TrackColumn.year.expression
        case .trackNumber: TrackColumn.trackNumber.expression
        case .discNumber: TrackColumn.discNumber.expression
        case .duration: TrackColumn.duration.expression
        case .sampleRate: TrackColumn.sampleRate.expression
        case .bitDepth: TrackColumn.bitDepth.expression
        case .playCount: TrackColumn.playCount.expression
        case .skipCount: TrackColumn.skipCount.expression
        case .rating: TrackColumn.rating.expression
        case .dateAdded: TrackColumn.dateAdded.expression
        case .lastPlayed: TrackColumn.lastPlayed.expression
        }
    }

    /// Whether `expression` is a folded sort key, so the typed value is folded the same way.
    var isFolded: Bool {
        switch self {
        case .title, .artist, .album, .albumArtist, .genre: true
        default: false
        }
    }
}

public enum SmartComparison: String, Codable, CaseIterable, Sendable {
    case contains, doesNotContain, `is`, isNot, startsWith, endsWith
    case greaterThan, lessThan
    /// Within the last so many days.
    case inLast
    /// Not within the last so many days, or never.
    case notInLast

    /// The comparisons that suit a field of `kind`, in the order the editor lists them.
    public static func comparisons(for kind: SmartField.Kind) -> [SmartComparison] {
        switch kind {
        case .text: [.contains, .doesNotContain, .is, .isNot, .startsWith, .endsWith]
        case .number: [.is, .isNot, .greaterThan, .lessThan]
        case .date: [.inLast, .notInLast]
        }
    }
}

/// At most `count` of the matching tracks, the first ones by `order`.
public struct SmartLimit: Codable, Equatable, Sendable {
    public var count: Int
    public var order: SmartOrder

    public init(count: Int, order: SmartOrder) {
        self.count = count
        self.order = order
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case count, order
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(decoder, CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        count = try container.decode(Int.self, forKey: .count)
        order = try container.decode(SmartOrder.self, forKey: .order)
        guard count > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .count, in: container, debugDescription: "a limit needs at least 1 track")
        }
    }
}

/// Which tracks a limit keeps.
public enum SmartOrder: String, Codable, CaseIterable, Sendable {
    case title, artist, album, recentlyAdded, recentlyPlayed, mostPlayed, leastPlayed,
        highestRated

    /// Ties go by path, which an index rebuild keeps, so the same tracks are picked after one.
    var sql: String {
        let order =
            switch self {
            case .title: "\(TrackColumn.title.expression) ASC"
            case .artist: "\(TrackColumn.artist.expression) ASC"
            case .album: "\(TrackColumn.album.expression) ASC"
            case .recentlyAdded: "\(TrackColumn.dateAdded.expression) DESC"
            // SQLite puts nulls, never played, last in a descending order.
            case .recentlyPlayed: "\(TrackColumn.lastPlayed.expression) DESC"
            case .mostPlayed: "\(TrackColumn.playCount.expression) DESC"
            case .leastPlayed: "\(TrackColumn.playCount.expression) ASC"
            case .highestRated: "\(TrackColumn.rating.expression) DESC"
            }
        return order + ", f.path"
    }
}

/// Every join a rule or a sort can need, from tracks `t`. Each joins on a unique key, so SQLite
/// leaves out the ones a statement doesn't use.
let trackJoins = """
    JOIN files f ON f.id = t.file_id
    LEFT JOIN artists ar ON ar.id = t.artist_id
    LEFT JOIN artists aa ON aa.id = t.album_artist_id
    LEFT JOIN albums al ON al.id = t.album_id
    LEFT JOIN genres g ON g.id = t.genre_id
    LEFT JOIN plays p ON p.path = f.path
    LEFT JOIN ratings r ON r.path = f.path
    """

private let secondsPerDay = 86_400.0

extension SmartRules {
    /// A condition on tracks `t` that holds for the tracks the rules pick, and the values it
    /// binds. Dates count back from `now`, in seconds since 1970.
    func condition(now: Double) -> (sql: String, values: [(any SQLiteValue)?]) {
        var values: [(any SQLiteValue)?] = []
        let clauses = rules.map { rule in
            let (sql, ruleValues) = rule.condition(now: now)
            values += ruleValues
            return sql
        }
        var sql = "SELECT t.file_id FROM tracks t \(trackJoins)"
        if !clauses.isEmpty {
            sql += " WHERE " + clauses.joined(separator: match == .all ? " AND " : " OR ")
        }
        if let limit {
            sql += " ORDER BY \(limit.order.sql) LIMIT ?"
            values.append(limit.count)
        }
        return ("t.file_id IN (\(sql))", values)
    }
}

extension SmartRule {
    fileprivate func condition(now: Double) -> (String, [(any SQLiteValue)?]) {
        let expression = field.expression
        switch value {
        case .text(let typed):
            let text = field.isFolded ? sortKey(typed) : typed
            let escaped = escapeLike(text)
            // A missing tag is empty text, so "doesn't contain" holds for it.
            let subject = "ifnull(\(expression), '')"
            let like = "\(subject) LIKE ? ESCAPE '\\'"
            let notLike = "\(subject) NOT LIKE ? ESCAPE '\\'"
            switch comparison {
            case .contains: return (like, ["%\(escaped)%"])
            case .doesNotContain: return (notLike, ["%\(escaped)%"])
            case .is: return (like, [escaped])
            case .isNot: return (notLike, [escaped])
            case .startsWith: return (like, ["\(escaped)%"])
            case .endsWith: return (like, ["%\(escaped)"])
            case .greaterThan, .lessThan, .inLast, .notInLast:
                preconditionFailure("\(comparison) on text; SmartRule.problem rejects it")
            }
        case .number(let number):
            switch comparison {
            case .is: return ("\(expression) = ?", [number])
            case .isNot: return ("\(expression) IS NOT ?", [number])
            case .greaterThan: return ("\(expression) > ?", [number])
            case .lessThan: return ("\(expression) < ?", [number])
            case .inLast: return ("\(expression) >= ?", [now - Double(number) * secondsPerDay])
            case .notInLast:
                return (
                    "(\(expression) IS NULL OR \(expression) < ?)",
                    [now - Double(number) * secondsPerDay]
                )
            case .contains, .doesNotContain, .startsWith, .endsWith:
                preconditionFailure("\(comparison) on a number; SmartRule.problem rejects it")
            }
        }
    }
}

/// `text` with LIKE's wildcards and the escape character itself escaped.
private func escapeLike(_ text: String) -> String {
    var escaped = ""
    for character in text {
        if character == "%" || character == "_" || character == "\\" { escaped.append("\\") }
        escaped.append(character)
    }
    return escaped
}
