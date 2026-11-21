import Foundation
import Settings

/// A read's query string, taken strictly (ADR 0215): each key at most once, only the keys the
/// route names, and each value in the form its key takes, so a mistake is a 400 rather than
/// read as something near it.
struct RemoteQuery: Sendable {
    static let genre = "genre"
    static let artist = "artist"
    static let album = "album"
    static let albums = "albums"
    static let sort = "sort"
    static let descending = "descending"
    static let offset = "offset"
    static let limit = "limit"
    static let text = "q"

    private let values: [String: String]
    private let problem: String?

    /// `query` as the request's target has it after `?`; nil for none.
    init(_ query: String?) {
        var values: [String: String] = [:]
        var problem: String?
        for pair in (query ?? "").split(separator: "&", omittingEmptySubsequences: false)
        where !(query ?? "").isEmpty {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                let key = String(parts[0]).removingPercentEncoding,
                let value = parts[1].replacingOccurrences(of: "+", with: " ")
                    .removingPercentEncoding
            else {
                problem = "the query string isn't key=value pairs"
                break
            }
            guard values.updateValue(value, forKey: key) == nil else {
                problem = "\(key) appears more than once"
                break
            }
        }
        self.values = values
        self.problem = problem
    }

    /// Throws unless every key is one of `keys`.
    func only(_ keys: Set<String>) throws(RemoteRefusal) {
        if let problem { throw RemoteRefusal(problem) }
        if let unknown = values.keys.sorted().first(where: { !keys.contains($0) }) {
            throw RemoteRefusal("\(unknown) isn't a key this read takes")
        }
    }

    /// The ID under `key`, nil when it's absent.
    func id(_ key: String) throws(RemoteRefusal) -> Int64? {
        guard let text = values[key] else { return nil }
        guard let id = Self.id(text) else { throw RemoteRefusal("\(key) must be an ID") }
        return id
    }

    /// Up to `limit` IDs between commas under `key`, at least one.
    func ids(_ key: String, limit: Int) throws(RemoteRefusal) -> [Int64] {
        let parts = (values[key] ?? "").split(separator: ",", omittingEmptySubsequences: false)
        let ids = parts.compactMap { Self.id(String($0)) }
        guard ids.count == parts.count, (1...limit).contains(ids.count) else {
            throw RemoteRefusal("\(key) must be 1 to \(limit) IDs between commas")
        }
        return ids
    }

    /// The column to sort by, nil when none is given.
    func column() throws(RemoteRefusal) -> TrackColumn? {
        guard let text = values[Self.sort] else { return nil }
        guard let column = TrackColumn(rawValue: text), column.isSortable else {
            throw RemoteRefusal("\(text) isn't a column to sort by")
        }
        return column
    }

    /// Whether `key` is `1`; absent or `0` is false.
    func flag(_ key: String) throws(RemoteRefusal) -> Bool {
        switch values[key] {
        case nil, "0": return false
        case "1": return true
        default: throw RemoteRefusal("\(key) must be 0 or 1")
        }
    }

    /// The positions `offset` and `limit` ask for: `limit` from 1 to `limit`, both needed.
    func window(limit maximum: Int) throws(RemoteRefusal) -> Range<Int> {
        guard let offset = values[Self.offset].flatMap(Self.natural),
            let limit = values[Self.limit].flatMap(Self.natural), (1...maximum).contains(limit),
            offset <= Int.max - limit
        else { throw RemoteRefusal("offset and limit must be given, limit from 1 to \(maximum)") }
        return offset..<(offset + limit)
    }

    /// The search text: some, and at most `maximumText` bytes.
    func text() throws(RemoteRefusal) -> String {
        guard let text = values[Self.text], !text.isEmpty,
            text.utf8.count <= Self.maximumTextBytes
        else { throw RemoteRefusal("q must be 1 to \(Self.maximumTextBytes) bytes of search") }
        return text
    }

    /// Longer than anyone types into a phone's search field.
    static let maximumTextBytes = 256

    private static func id(_ text: String) -> Int64? {
        natural(text).flatMap { $0 > 0 ? Int64($0) : nil }
    }

    /// 1 to 18 ASCII digits.
    private static func natural(_ text: String) -> Int? {
        guard (1...18).contains(text.count), text.allSatisfy({ $0.isASCII && $0.isNumber })
        else { return nil }
        return Int(text)
    }
}

/// Why the remote refused a read or a command, as its reply says.
public struct RemoteRefusal: Error, CustomStringConvertible {
    public var description: String

    init(_ description: String) { self.description = description }
}
