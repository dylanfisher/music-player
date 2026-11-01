import Foundation
import Settings
import Testing

@testable import Library

/// What SQL, LIKE and FTS5 give meaning to, and a value near the rule limit (ADR 0025).
private let hostile: [(word: String, text: String)] = [
    ("kilo", "'"), ("lima", "\""), ("mike", ";"), ("oscar", "--"), ("papa", "%"),
    ("quebec", "_"), ("romeo", "\\"), ("sierra", "'; DROP TABLE tracks; --"),
    ("tango", String(repeating: "y", count: SmartRule.maximumTextBytes - 100)),
]
private let plainWord = "golf"

/// The tag value every text field of a word's file holds.
private func value(_ word: String) -> String {
    word == plainWord ? "\(word) plain" : "\(word) a\(hostile.first { $0.word == word }!.text)b"
}

/// A FLAC file with STREAMINFO and a Vorbis comment, which is all the scan reads.
private func flac(tags: [String: String]) -> Data {
    var info = Data([0x10, 0x00, 0x10, 0x00]) + Data(count: 6)
    let packed = UInt64(44_100) << 44 | UInt64(1) << 41 | UInt64(15) << 36 | UInt64(4410)
    for shift in stride(from: 56, through: 0, by: -8) { info.append(UInt8(packed >> shift & 0xFF)) }
    info += Data(count: 16)
    func littleEndian(_ value: Int) -> Data {
        Data((0..<4).map { UInt8(value >> ($0 * 8) & 0xFF) })
    }
    var comment = littleEndian(0) + littleEndian(tags.count)
    for (key, value) in tags.sorted(by: { $0.key < $1.key }) {
        let field = Data("\(key)=\(value)".utf8)
        comment += littleEndian(field.count) + field
    }
    func block(_ type: UInt8, _ body: Data) -> Data {
        Data([
            type, UInt8(body.count >> 16), UInt8(body.count >> 8 & 0xFF), UInt8(body.count & 0xFF),
        ])
            + body
    }
    return Data("fLaC".utf8) + block(0, info) + block(0x84, comment) + Data([0xFF, 0xF8, 0, 0])
}

/// A library of one file per hostile text and one plain file. The hostile text is in every text
/// tag and, where a file name can hold it, the name.
private func hostileLibrary() throws -> LibraryIndex {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hostile-\(UUID().uuidString)")
    let root = directory.appendingPathComponent("Music")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for word in hostile.map(\.word) + [plainWord] {
        let text = value(word)
        let tags = Dictionary(
            uniqueKeysWithValues: [
                "TITLE", "ARTIST", "ALBUM", "ALBUMARTIST", "GENRE", "COMPOSER", "COMMENT",
            ].map { ($0, text) })
        let name = text.count > 200 ? word : text
        try flac(tags: tags).write(to: root.appendingPathComponent("\(name).flac"))
    }
    let databaseURL = directory.appendingPathComponent("library.sqlite")
    let summary = try LibraryScanner(databaseURL: databaseURL).scan(
        WatchedFolder(path: root.path, kind: .local))
    #expect(summary.read == hostile.count + 1)
    #expect(summary.failed == 0)
    return try LibraryIndex(at: databaseURL)
}

/// What a rule should pick: LIKE folds ASCII case, and the folded fields fold the rest.
private func expected(
    _ comparison: SmartComparison, _ typed: String, in values: [Int64: String], folded: Bool
) -> Set<Int64> {
    let fold = { (text: String) in folded ? sortKey(text).lowercased() : text.lowercased() }
    let typed = fold(typed)
    return Set(
        values.filter { _, value in
            let value = fold(value)
            switch comparison {
            case .contains: return value.contains(typed)
            case .doesNotContain: return !value.contains(typed)
            case .is: return value == typed
            case .isNot: return value != typed
            case .startsWith: return value.hasPrefix(typed)
            case .endsWith: return value.hasSuffix(typed)
            case .greaterThan, .lessThan, .inLast, .notInLast:
                preconditionFailure("\(comparison) isn't a text comparison")
            }
        }.keys)
}

@Test func everyRuleFieldAndTheSearchBoxMatchHostileTextLiterally() throws {
    let index = try hostileLibrary()
    let ids = try index.trackIDs(sortedBy: .path)
    let rows = try index.rows(ids: ids)
    let idOf = Dictionary(
        uniqueKeysWithValues: rows.map { ($0.title.split(separator: " ")[0], $0.id) })
    let tagValues = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.title) })
    #expect(tagValues.values.sorted() == (hostile.map(\.word) + [plainWord]).map(value).sorted())

    for field in SmartField.allCases where field.kind == .text {
        let values =
            switch field {
            case .path: Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.path) })
            case .codec: Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.codec) })
            default: tagValues
            }
        for (word, text) in hostile {
            let typedValues = [text, "a\(text)b", value(word), "\(word) a\(text)", "\(text)b"]
            for typed in typedValues {
                for comparison in SmartComparison.comparisons(for: .text) {
                    let rule = SmartRule(field, comparison, .text(typed))
                    #expect(rule.problem == nil)
                    let rules = SmartRules(match: .all, rules: [rule])
                    #expect(try SmartRules(json: try rules.json()) == rules)
                    let id = try index.createPlaylist(named: value(word), rules: rules)
                    let found = Set(
                        try index.trackIDs(TrackFilter(source: .playlist(id)), sortedBy: .path))
                    #expect(
                        found == expected(comparison, typed, in: values, folded: field.isFolded),
                        "\(field) \(comparison) \(typed.prefix(40))")
                    try index.deletePlaylist(id)
                }
            }
        }
    }

    func search(_ text: String) throws -> Set<Int64> {
        Set(try index.trackIDs(TrackFilter(search: text), sortedBy: .path))
    }
    let everything = Set(ids)
    for (word, text) in hostile {
        let only: Set<Int64> = [idOf[Substring(word)]!]
        let hasLetters = text.contains(where: \.isLetter)
        // Typed alone, punctuation has no word to look for, so nothing is filtered. Typed onto
        // the word, it's a separator; letters there make a longer word that no file has.
        if !hasLetters { #expect(try search(text) == everything, "\(text)") }
        let joined: Set<Int64> = text.first!.isLetter ? [] : only
        #expect(try search("\(word)\(text)") == joined, "\(word)")
        #expect(try search("\(word)\u{0}\(text)") == joined, "\(word) with a NUL")
        #expect(try search(value(word)) == only, "\(word)")
    }
    #expect(try search("a" + hostile.last!.text) == [idOf["tango"]!])
    #expect(try search("drop table tracks") == [idOf["sierra"]!])
    #expect(try index.trackCount() == hostile.count + 1)
}

@Test func ruleTextPastTheLimitIsRefused() throws {
    let limit = SmartRule.maximumTextBytes
    #expect(
        SmartRule(.title, .contains, .text(String(repeating: "é", count: limit / 2))).problem == nil
    )
    let long = SmartRule(.title, .contains, .text(String(repeating: "é", count: limit / 2 + 1)))
    #expect(long.problem != nil)
    #expect(SmartRule(.comment, .is, .text("a\u{0}b")).problem != nil)
    let json = try SmartRules(match: .all, rules: [SmartRule(.title, .is, .text("a"))]).json()
        .replacingOccurrences(of: "\"a\"", with: "\"a\\u0000b\"")
    #expect(throws: DecodingError.self) { try SmartRules(json: json) }
}
