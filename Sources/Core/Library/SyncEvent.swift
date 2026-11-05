import Foundation

/// One change a machine shares through its log (ADR 0038). Paths are sync paths: the share's
/// name, the folder's path in the share and the path under it, in NFC.
enum SyncEvent: Equatable, Sendable {
    case play(path: String, at: Double)
    case skip(path: String)
    /// Plays and skips an import from `player` added, and its Last Played.
    case counts(
        path: String, player: PlayerLibrary.Player, plays: Int, skips: Int, lastPlayed: Double?)
    /// 0 clears the rating.
    case rating(path: String, stars: Int)
    /// Liked, or no opinion: the latest of this and `disliked` is the path's opinion.
    case loved(path: String, loved: Bool)
    case disliked(path: String)
    /// When a machine first saw the path: Date Added. An import's, one date per path.
    case added(path: String, at: Double)
    /// When a machine's scan first saw the files `names` in the folder `folder`: Date Added
    /// for each, one line for a scan batch's new files in one folder (ADR 0098).
    case addedFiles(folder: String, names: [String], at: Double)
    case move(from: String, to: String)
    /// `rules` is a smart playlist's `SmartRules` JSON; nil for a manual playlist.
    case playlistCreate(playlist: String, name: String, rules: String?)
    case playlistRename(playlist: String, name: String)
    case playlistRules(playlist: String, rules: String)
    /// The whole list, in order.
    case playlistEntries(playlist: String, paths: [String])
    case playlistDelete(playlist: String)
}

/// An event as one line of a log: its sequence number in the log, its clock and the event.
package struct SyncRecord: Equatable, Sendable {
    var seq: Int64
    var clock: SyncClock
    var event: SyncEvent

    /// What a log may hold, for its writer and every reader.
    package static let maximumLineBytes = 4 << 20
    static let maximumLogBytes = 1 << 30
    static let maximumEvents = 4_000_000
    /// The largest sequence number, and count, JSON carries exactly.
    static let seqRange: ClosedRange<Int64> = 1...(1 << 53)
    /// What a time in a log may be: seconds since 1970, up to 2100.
    static let secondsRange: ClosedRange<Double> = 0...4_102_444_800
    static let countRange: ClosedRange<Int64> = 0...Int64(Int32.max)
    static let maximumNameBytes = 4096
    static let maximumPathBytes = 4096
    /// Entries one playlist event lists at most; a longer playlist isn't synced.
    static let maximumEntries = 100_000
    /// Names one `addedFiles` event lists at most: a scan batch's, so a line of names as long
    /// as a path may be stays under `maximumLineBytes`.
    static let maximumAddedNames = 500

    /// The line, without its line break: a JSON object with its keys in a fixed order.
    package var line: String {
        var fields: [(SyncKey, SyncJSON)] = [
            (.seq, .integer(seq)), (.ms, .integer(clock.ms)), (.n, .integer(clock.counter)),
            (.event, .string(event.name.rawValue)),
        ]
        fields += event.fields
        return "{"
            + fields.map { "\(jsonString($0.0.rawValue)):\($0.1.text)" }.joined(separator: ",")
            + "}"
    }

    /// Decodes a line without its line break. Every key is required, nothing else is allowed,
    /// and every value is checked (ADR 0025).
    package init(line bytes: ArraySlice<UInt8>) throws(SyncLineProblem) {
        var parser = SyncJSONParser(bytes)
        var fields = SyncFields(object: try parser.object())
        seq = try fields.take(.seq).integer(.seq, in: Self.seqRange)
        clock = SyncClock(
            ms: try fields.take(.ms).integer(.ms, in: SyncClock.msRange),
            counter: try fields.take(.n).integer(.n, in: SyncClock.counterRange))
        event = try SyncEvent(try fields.take(.event).string(.event), &fields)
        if let extra = fields.object.keys.sorted().first { throw .unknownKey(clipped(extra)) }
    }

    init(seq: Int64, clock: SyncClock, event: SyncEvent) {
        self.seq = seq
        self.clock = clock
        self.event = event
    }

    /// The line of a play of `path` at `at`, event `seq` of its log made at `ms`, for the bench
    /// to write a million without a million transactions.
    package static func playLine(seq: Int64, ms: Int64, path: String, at: Double) -> String {
        SyncRecord(seq: seq, clock: SyncClock(ms: ms, counter: 0), event: .play(path: path, at: at))
            .line
    }
}

extension SyncEvent {
    /// The event that gives `path` `opinion`, nil for none.
    static func opinion(path: String, _ opinion: TrackOpinion?) -> SyncEvent {
        opinion == .disliked ? .disliked(path: path) : .loved(path: path, loved: opinion == .liked)
    }

    /// What applying the event costs, toward a sync's batch: one, or one per entry or name.
    var work: Int {
        switch self {
        case .playlistEntries(_, let paths): max(1, paths.count)
        case .addedFiles(_, let names, _): names.count
        default: 1
        }
    }

    var name: SyncEventName {
        switch self {
        case .play: .play
        case .skip: .skip
        case .counts: .counts
        case .rating: .rating
        case .loved: .loved
        case .disliked: .disliked
        case .added: .added
        case .addedFiles: .addedFiles
        case .move: .move
        case .playlistCreate: .playlistCreate
        case .playlistRename: .playlistRename
        case .playlistRules: .playlistRules
        case .playlistEntries: .playlistEntries
        case .playlistDelete: .playlistDelete
        }
    }

    fileprivate var fields: [(SyncKey, SyncJSON)] {
        switch self {
        case .play(let path, let at): [(.path, .string(path)), (.at, .number(at))]
        case .skip(let path): [(.path, .string(path))]
        case .counts(let path, let player, let plays, let skips, let lastPlayed):
            [
                (.path, .string(path)), (.player, .string(player.rawValue)),
                (.plays, .integer(Int64(plays))),
                (.skips, .integer(Int64(skips))),
                (.lastPlayed, lastPlayed.map { .number($0) } ?? .null),
            ]
        case .rating(let path, let stars):
            [(.path, .string(path)), (.stars, .integer(Int64(stars)))]
        case .loved(let path, let loved): [(.path, .string(path)), (.loved, .bool(loved))]
        case .disliked(let path): [(.path, .string(path))]
        case .added(let path, let at): [(.path, .string(path)), (.at, .number(at))]
        case .addedFiles(let folder, let names, let at):
            [(.folder, .string(folder)), (.names, .strings(names)), (.at, .number(at))]
        case .move(let from, let to): [(.from, .string(from)), (.to, .string(to))]
        case .playlistCreate(let playlist, let name, let rules):
            [
                (.playlist, .string(playlist)), (.name, .string(name)),
                (.rules, rules.map { .string($0) } ?? .null),
            ]
        case .playlistRename(let playlist, let name):
            [(.playlist, .string(playlist)), (.name, .string(name))]
        case .playlistRules(let playlist, let rules):
            [(.playlist, .string(playlist)), (.rules, .string(rules))]
        case .playlistEntries(let playlist, let paths):
            [(.playlist, .string(playlist)), (.paths, .strings(paths))]
        case .playlistDelete(let playlist): [(.playlist, .string(playlist))]
        }
    }
}

/// The keys of a log line.
enum SyncKey: String {
    case seq, ms, n, event, path, at, player, plays, skips, lastPlayed, stars, loved, from, to
    case playlist
    case name, rules, paths
    case folder, names
}

/// What `event` names in a log line.
enum SyncEventName: String {
    case play, skip, counts, rating, loved, disliked, added, addedFiles, move, playlistCreate
    case playlistRename
    case playlistRules, playlistEntries, playlistDelete
}

/// A line's keys not yet decoded.
private struct SyncFields {
    var object: [String: SyncJSON]

    mutating func take(_ key: SyncKey) throws(SyncLineProblem) -> SyncJSON {
        guard let value = object.removeValue(forKey: key.rawValue) else {
            throw .missing(key.rawValue)
        }
        return value
    }

    mutating func path(_ key: SyncKey) throws(SyncLineProblem) -> String {
        try take(key).path(key)
    }

    mutating func playlist() throws(SyncLineProblem) -> String {
        try take(.playlist).playlistID()
    }
}

extension SyncEvent {
    /// The event `name`, from its keys in `fields`.
    fileprivate init(_ name: String, _ fields: inout SyncFields) throws(SyncLineProblem) {
        guard let known = SyncEventName(rawValue: name) else { throw .unknownEvent(clipped(name)) }
        switch known {
        case .play:
            self = .play(path: try fields.path(.path), at: try fields.take(.at).seconds(.at))
        case .skip: self = .skip(path: try fields.path(.path))
        case .counts:
            let lastPlayed = try fields.take(.lastPlayed)
            let player = try fields.take(.player).string(.player)
            guard let known = PlayerLibrary.Player(rawValue: player) else {
                throw .bad(.player, "isn't a player an import reads")
            }
            self = .counts(
                path: try fields.path(.path), player: known,
                plays: Int(try fields.take(.plays).integer(.plays, in: SyncRecord.countRange)),
                skips: Int(try fields.take(.skips).integer(.skips, in: SyncRecord.countRange)),
                lastPlayed: lastPlayed == .null ? nil : try lastPlayed.seconds(.lastPlayed))
        case .rating:
            self = .rating(
                path: try fields.path(.path),
                stars: Int(
                    try fields.take(.stars).integer(.stars, in: 0...Int64(SmartField.maxRating))))
        case .loved:
            self = .loved(
                path: try fields.path(.path), loved: try fields.take(.loved).bool(.loved))
        case .disliked: self = .disliked(path: try fields.path(.path))
        case .added:
            self = .added(path: try fields.path(.path), at: try fields.take(.at).seconds(.at))
        case .addedFiles:
            let folder = try fields.path(.folder)
            guard case .strings(let names) = try fields.take(.names) else {
                throw .bad(.names, "isn't a list of strings")
            }
            guard (1...SyncRecord.maximumAddedNames).contains(names.count) else {
                throw .bad(.names, "lists no names or over \(SyncRecord.maximumAddedNames)")
            }
            var checked: [String] = []
            for name in names {
                guard !name.contains("/") else { throw .bad(.names, "holds a name with a /") }
                // The whole path is checked, as a path's would be. NFC leaves the folder and
                // the slash as they are, so the name is what follows them.
                let path = try SyncJSON.string(folder + "/" + name).path(.names)
                checked.append(
                    String(decoding: path.utf8.dropFirst(folder.utf8.count + 1), as: UTF8.self))
            }
            self = .addedFiles(
                folder: folder, names: checked, at: try fields.take(.at).seconds(.at))
        case .move: self = .move(from: try fields.path(.from), to: try fields.path(.to))
        case .playlistCreate:
            let rules = try fields.take(.rules)
            self = .playlistCreate(
                playlist: try fields.playlist(), name: try fields.take(.name).name(),
                rules: rules == .null ? nil : try rules.rules())
        case .playlistRename:
            self = .playlistRename(
                playlist: try fields.playlist(), name: try fields.take(.name).name())
        case .playlistRules:
            self = .playlistRules(
                playlist: try fields.playlist(), rules: try fields.take(.rules).rules())
        case .playlistEntries:
            guard case .strings(let paths) = try fields.take(.paths) else {
                throw .bad(.paths, "isn't a list of strings")
            }
            guard paths.count <= SyncRecord.maximumEntries else {
                throw .bad(.paths, "lists over \(SyncRecord.maximumEntries) entries")
            }
            var checked: [String] = []
            for path in paths { checked.append(try SyncJSON.string(path).path(.paths)) }
            self = .playlistEntries(playlist: try fields.playlist(), paths: checked)
        case .playlistDelete: self = .playlistDelete(playlist: try fields.playlist())
        }
    }
}

/// Why a log's line was refused.
package enum SyncLineProblem: Error, Equatable, CustomStringConvertible {
    case notJSON(String)
    case missing(String)
    case unknownKey(String)
    case unknownEvent(String)
    case badValue(String, String)

    static func bad(_ key: SyncKey, _ reason: String) -> SyncLineProblem {
        .badValue(key.rawValue, reason)
    }

    package var description: String {
        switch self {
        case .notJSON(let detail): "isn't a JSON object of the log's form: \(detail)"
        case .missing(let key): "has no \"\(key)\""
        case .unknownKey(let key): "has the unknown key \"\(key)\""
        case .unknownEvent(let name): "has the unknown event \"\(name)\""
        case .badValue(let key, let reason): "\"\(key)\" \(reason)"
        }
    }
}

/// The most of a log's own text a problem keeps, so a hundred problems a log stay small.
let maximumQuotedCharacters = 200

/// `text`, cut to `maximumQuotedCharacters` with "…" when it's longer.
func clipped(_ text: String) -> String {
    text.count > maximumQuotedCharacters ? text.prefix(maximumQuotedCharacters) + "…" : text
}

/// A playlist's ID in every log: 32 lowercase hex digits, as `newSyncID` makes.
func isSyncID(_ text: String) -> Bool {
    text.utf8.count == 32
        && text.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
}

/// A new random ID for a playlist.
func newSyncID() -> String {
    UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
}

/// A value of a log line, which holds only these.
enum SyncJSON: Equatable {
    case string(String)
    case integer(Int64)
    case number(Double)
    case bool(Bool)
    case null
    case strings([String])

    var text: String {
        switch self {
        case .string(let value): jsonString(value)
        case .integer(let value): String(value)
        // Swift prints the shortest text that reads back as the same Double.
        case .number(let value): "\(value)"
        case .bool(let value): value ? "true" : "false"
        case .null: nullText
        case .strings(let values): "[" + values.map(jsonString).joined(separator: ",") + "]"
        }
    }

    fileprivate func integer(_ key: SyncKey, in range: ClosedRange<Int64>) throws(SyncLineProblem)
        -> Int64
    {
        guard case .integer(let value) = self else { throw .bad(key, "isn't an integer") }
        guard range.contains(value) else {
            throw .bad(key, "\(value) isn't in \(range.lowerBound)...\(range.upperBound)")
        }
        return value
    }

    fileprivate func seconds(_ key: SyncKey) throws(SyncLineProblem) -> Double {
        let value: Double
        switch self {
        case .integer(let whole): value = Double(whole)
        case .number(let number): value = number
        default: throw .bad(key, "isn't a number")
        }
        let range = SyncRecord.secondsRange
        guard range.contains(value) else {
            throw .bad(key, "\(value) isn't in \(range.lowerBound)...\(range.upperBound)")
        }
        return value
    }

    fileprivate func string(_ key: SyncKey) throws(SyncLineProblem) -> String {
        guard case .string(let value) = self else { throw .bad(key, "isn't a string") }
        return value
    }

    fileprivate func bool(_ key: SyncKey) throws(SyncLineProblem) -> Bool {
        guard case .bool(let value) = self else { throw .bad(key, "isn't true or false") }
        return value
    }

    /// A relative path, folded to NFC, with no empty, `.` or `..` part and no NUL.
    fileprivate func path(_ key: SyncKey) throws(SyncLineProblem) -> String {
        let path = try string(key)
        guard !path.isEmpty, path.utf8.count <= SyncRecord.maximumPathBytes else {
            throw .bad(key, "is empty or over \(SyncRecord.maximumPathBytes) bytes")
        }
        guard !path.utf8.contains(0),
            !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: {
                $0.isEmpty || $0 == "." || $0 == ".."
            })
        else { throw .bad(key, "isn't a relative path without empty, . or .. parts") }
        // ASCII is already in NFC, and most paths are.
        return path.utf8.allSatisfy { $0 < 0x80 }
            ? path : path.precomposedStringWithCanonicalMapping
    }

    fileprivate func playlistID() throws(SyncLineProblem) -> String {
        let id = try string(.playlist)
        guard isSyncID(id) else { throw .bad(.playlist, "isn't 32 lowercase hex digits") }
        return id
    }

    /// A playlist's name: no control character, which would fake a line in a report.
    fileprivate func name() throws(SyncLineProblem) -> String {
        let name = try string(.name)
        guard name.utf8.count <= SyncRecord.maximumNameBytes,
            !name.unicodeScalars.contains(where: {
                // Format characters such as U+202E reorder what a report row shows.
                [.control, .format].contains($0.properties.generalCategory) || $0 == "\u{2028}"
                    || $0 == "\u{2029}"
            })
        else {
            throw .bad(
                .name,
                "is over \(SyncRecord.maximumNameBytes) bytes or holds a control or format character"
            )
        }
        return name
    }

    /// A smart playlist's rules, which must decode and be valid.
    fileprivate func rules() throws(SyncLineProblem) -> String {
        let json = try string(.rules)
        do {
            let rules = try SmartRules(json: json)
            if let problem = rules.rules.lazy.compactMap(\.problem).first ?? rules.limit?.problem {
                throw SyncLineProblem.bad(.rules, "\(problem)")
            }
        } catch let problem as SyncLineProblem {
            throw problem
        } catch {
            throw .bad(.rules, "aren't a smart playlist's rules: \(error)")
        }
        return json
    }
}

private let nullText = "null"

/// `text` as a JSON string: quotes, backslashes and control characters escaped, the rest as is.
func jsonString(_ text: String) -> String {
    var out = "\""
    for scalar in text.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
        default: out.unicodeScalars.append(scalar)
        }
    }
    return out + "\""
}

/// Reads one log line: a JSON object, without whitespace, of string keys, each once, whose
/// values are strings, numbers, true, false, null or lists of strings. Nothing else a log
/// writes, so nothing else is read.
struct SyncJSONParser {
    private let bytes: ArraySlice<UInt8>
    private var index: Int

    init(_ bytes: ArraySlice<UInt8>) {
        self.bytes = bytes
        index = bytes.startIndex
    }

    mutating func object() throws(SyncLineProblem) -> [String: SyncJSON] {
        try expect(UInt8(ascii: "{"))
        var object: [String: SyncJSON] = [:]
        if peek == UInt8(ascii: "}") {
            index += 1
        } else {
            while true {
                let key = try string()
                try expect(UInt8(ascii: ":"))
                guard object.updateValue(try value(), forKey: key) == nil else {
                    throw .notJSON("the key \"\(clipped(key))\" appears twice")
                }
                let next = try byte()
                if next == UInt8(ascii: "}") { break }
                guard next == UInt8(ascii: ",") else { throw unexpected(next) }
            }
        }
        guard index == bytes.endIndex else { throw .notJSON("text after the object") }
        return object
    }

    private var peek: UInt8? { index < bytes.endIndex ? bytes[index] : nil }

    private mutating func byte() throws(SyncLineProblem) -> UInt8 {
        guard let next = peek else { throw .notJSON("the line ends early") }
        index += 1
        return next
    }

    private mutating func expect(_ wanted: UInt8) throws(SyncLineProblem) {
        let next = try byte()
        guard next == wanted else { throw unexpected(next) }
    }

    private func unexpected(_ byte: UInt8) -> SyncLineProblem {
        .notJSON("unexpected byte 0x\(String(byte, radix: 16)) at \(index - 1 - bytes.startIndex)")
    }

    private mutating func value() throws(SyncLineProblem) -> SyncJSON {
        switch peek {
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "["):
            index += 1
            var strings: [String] = []
            if peek == UInt8(ascii: "]") {
                index += 1
                return .strings(strings)
            }
            while true {
                strings.append(try string())
                let next = try byte()
                if next == UInt8(ascii: "]") { return .strings(strings) }
                guard next == UInt8(ascii: ",") else { throw unexpected(next) }
            }
        case UInt8(ascii: "t"): return try word("true", .bool(true))
        case UInt8(ascii: "f"): return try word("false", .bool(false))
        case UInt8(ascii: "n"): return try word(nullText, .null)
        default: return try number()
        }
    }

    private mutating func word(_ text: String, _ value: SyncJSON) throws(SyncLineProblem)
        -> SyncJSON
    {
        for wanted in text.utf8 { try expect(wanted) }
        return value
    }

    private mutating func number() throws(SyncLineProblem) -> SyncJSON {
        let start = index
        func digits() -> Int {
            let from = index
            while let next = peek, (0x30...0x39).contains(next) { index += 1 }
            return index - from
        }
        if peek == UInt8(ascii: "-") { index += 1 }
        let integerStart = index
        guard digits() > 0 else { throw .notJSON("a value isn't a string, number or literal") }
        if bytes[integerStart] == UInt8(ascii: "0"), index - integerStart > 1 {
            throw .notJSON("a number has a leading zero")
        }
        var whole = true
        if peek == UInt8(ascii: ".") {
            index += 1
            whole = false
            guard digits() > 0 else { throw .notJSON("a number has no digits after its point") }
        }
        if peek == UInt8(ascii: "e") || peek == UInt8(ascii: "E") {
            index += 1
            whole = false
            if peek == UInt8(ascii: "+") || peek == UInt8(ascii: "-") { index += 1 }
            guard digits() > 0 else { throw .notJSON("a number has no exponent digits") }
        }
        let text = String(decoding: bytes[start..<index], as: UTF8.self)
        if whole {
            guard let value = Int64(text) else { throw .notJSON("the integer \(text) overflows") }
            return .integer(value)
        }
        guard let value = Double(text), value.isFinite else {
            throw .notJSON("the number \(text) isn't finite")
        }
        return .number(value)
    }

    private mutating func string() throws(SyncLineProblem) -> String {
        try expect(UInt8(ascii: "\""))
        var utf8: [UInt8] = []
        while true {
            let next = try byte()
            switch next {
            case UInt8(ascii: "\""):
                // Decoding replaces each invalid sequence, so different bytes mean invalid ones.
                let text = String(decoding: utf8, as: UTF8.self)
                guard text.utf8.elementsEqual(utf8) else { throw .notJSON("a string isn't UTF-8") }
                return text
            case UInt8(ascii: "\\"):
                let escape = try byte()
                switch escape {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): utf8.append(escape)
                case UInt8(ascii: "b"): utf8.append(0x08)
                case UInt8(ascii: "f"): utf8.append(0x0C)
                case UInt8(ascii: "n"): utf8.append(0x0A)
                case UInt8(ascii: "r"): utf8.append(0x0D)
                case UInt8(ascii: "t"): utf8.append(0x09)
                case UInt8(ascii: "u"):
                    var code = try hex4()
                    if (0xD800...0xDBFF).contains(code) {
                        guard try byte() == UInt8(ascii: "\\"), try byte() == UInt8(ascii: "u")
                        else { throw .notJSON("a lone surrogate") }
                        let low = try hex4()
                        guard (0xDC00...0xDFFF).contains(low) else {
                            throw .notJSON("a lone surrogate")
                        }
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    }
                    guard let scalar = Unicode.Scalar(code) else {
                        throw .notJSON("a lone surrogate")
                    }
                    utf8.append(contentsOf: String(Character(scalar)).utf8)
                default: throw unexpected(escape)
                }
            case 0..<0x20: throw .notJSON("a control character in a string")
            default: utf8.append(next)
            }
        }
    }

    private mutating func hex4() throws(SyncLineProblem) -> UInt32 {
        var code: UInt32 = 0
        for _ in 0..<4 {
            let next = try byte()
            guard let digit = UInt32(String(UnicodeScalar(next)), radix: 16) else {
                throw unexpected(next)
            }
            code = code << 4 | digit
        }
        return code
    }
}
