import Foundation
import Metadata
import Settings
import Testing

@testable import Fixtures
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

/// A FLAC file with STREAMINFO, a Vorbis comment and, given one, a front cover, which is all
/// the scan reads. Built here because Fixtures' `flacFile` writes only `FixtureTags`, which has
/// no composer, and MetadataTests' `flac(_:)` is in a test target this one can't import;
/// Fixtures' byte helpers do the packing.
func taggedFLAC(tags: [String: String], cover: Data? = nil) -> Data {
    var file = Data()
    file.append(ascii: flacMarker)
    file.append(0)
    file.appendUInt24(34)
    file.appendBigEndian(UInt16(4096))
    file.appendBigEndian(UInt16(4096))
    file.append(Data(count: 6))
    file.appendBigEndian(UInt64(44_100) << 44 | UInt64(1) << 41 | UInt64(15) << 36 | 4410)
    file.append(Data(count: 16))
    var comment = Data()
    comment.appendLittleEndian(UInt32(0))
    comment.appendLittleEndian(UInt32(tags.count))
    for (key, value) in tags.sorted(by: { $0.key < $1.key }) {
        comment.appendLittleEndian(UInt32("\(key)=\(value)".utf8.count))
        comment.append(ascii: "\(key)=\(value)")
    }
    file.append(cover == nil ? 0x84 : 0x04)
    file.appendUInt24(comment.count)
    file += comment
    if let cover {
        var picture = Data()
        picture.appendBigEndian(UInt32(3))
        picture.appendBigEndian(UInt32(9))
        picture.append(ascii: "image/png")
        picture.append(Data(count: 20))
        picture.appendBigEndian(UInt32(cover.count))
        picture += cover
        file.append(0x86)
        file.appendUInt24(picture.count)
        file += picture
    }
    return file + Data([0xFF, 0xF8, 0, 0])
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
                "GROUPING", "CATALOGNUMBER", "BARCODE", "KEY", "CONDUCTOR", "LYRICIST", "LABEL",
                "COPYRIGHT", "ENCODEDBY", "DESCRIPTION", "DISCSUBTITLE", "WORK", "MOVEMENTNAME",
                "ORIGINALDATE", "MOOD",
            ].map { ($0, text) })
        let name = text.count > 200 ? word : text
        try taggedFLAC(tags: tags).write(to: root.appendingPathComponent("\(name).flac"))
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
            case .fileName: Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.fileName) })
            case .fileType: Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.fileType) })
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

@Test func hostileFilesFailAloneAndTheScanCarriesOn() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hostile-\(UUID().uuidString)")
    let root = directory.appendingPathComponent("Music")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let good = taggedFLAC(tags: ["TITLE": "good"])
    var oversized = good
    oversized[oversized.startIndex + 5...oversized.startIndex + 7] = Data([0xFF, 0xFF, 0xFF])
    let hostileFiles: [(String, Data)] = [
        ("block past the end.flac", oversized),
        (
            "atom of UInt64.max.m4a",
            Data([0, 0, 0, 1]) + Data("ftyp".utf8) + Data(repeating: 0xFF, count: 8)
        ),
        ("empty.mp3", Data()),
        ("noise.wav", Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })),
    ]
    for (name, data) in hostileFiles { try data.write(to: root.appendingPathComponent(name)) }
    try good.write(to: root.appendingPathComponent("good.flac"))

    let databaseURL = directory.appendingPathComponent("library.sqlite")
    let summary = try LibraryScanner(databaseURL: databaseURL).scan(
        WatchedFolder(path: root.path, kind: .local))
    #expect(summary.failed == hostileFiles.count)
    let index = try LibraryIndex(at: databaseURL)
    #expect(try index.rows(ids: try index.trackIDs(sortedBy: .path)).map(\.title) == ["good"])
    let failures = try index.fileIssues().filter {
        if case .failure = $0.problem { return true }
        return false
    }
    #expect(
        Set(failures.map { ($0.path as NSString).lastPathComponent })
            == Set(hostileFiles.map(\.0)))
}

@Test func aWalkListsAtMostItsCapOfProblemsAndStillProtectsEveryUnreadableFolder() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hostile-\(UUID().uuidString)")
    let root = directory.appendingPathComponent("Music")
    let locked = root.appendingPathComponent("zz locked")
    try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
    try taggedFLAC(tags: ["TITLE": "kept"]).write(to: locked.appendingPathComponent("kept.flac"))
    let links = ScanPipeline.maximumIssues + 50
    for number in 0..<links {
        #expect(symlink("/nowhere", root.appendingPathComponent("link \(number)").path) == 0)
    }
    let databaseURL = directory.appendingPathComponent("library.sqlite")
    let scanner = LibraryScanner(databaseURL: databaseURL)
    let folder = WatchedFolder(path: root.path, kind: .local)
    var summary = try scanner.scan(folder)
    #expect(summary.read == 1)
    #expect(summary.issues.count == ScanPipeline.maximumIssues + 1)
    #expect(summary.issues.last?.detail.hasPrefix("50 more problems in this folder") == true)

    chmod(locked.path, 0)
    defer { chmod(locked.path, 0o755) }
    summary = try scanner.scan(folder)
    #expect(summary.issues.count == ScanPipeline.maximumIssues + 1)
    #expect(summary.removed == 0)
    #expect(try LibraryIndex(at: databaseURL).trackCount() == 1)
}
