import Foundation
import Settings
import Testing

@testable import Library

private func decode(_ json: String) throws -> SmartRules {
    try SmartRules(json: json)
}

@Test func rulesReadBackAsStored() throws {
    let rules = SmartRules(
        match: .any,
        rules: [
            SmartRule(.artist, .contains, .text("björk")),
            SmartRule(.year, .greaterThan, .number(1990)),
            SmartRule(.lastPlayed, .inLast, .number(7)),
        ], limit: SmartLimit(count: 25, order: .mostPlayed))
    #expect(try SmartRules(json: try rules.json()) == rules)
}

@Test func storedRulesRejectUnknownKeysAtEveryLevel() {
    let rule = #"{"field": "title", "comparison": "contains", "value": "a"}"#
    let limit = #"{"count": 5, "order": "title"}"#
    for json in [
        #"{"match": "all", "rules": [], "extra": 1}"#,
        #"{"match": "all", "rules": [{"field": "title", "comparison": "contains", "value": "a", "x": 1}]}"#,
        #"{"match": "all", "rules": [], "limit": {"count": 5, "order": "title", "x": 1}}"#,
    ] {
        #expect(throws: DecodingError.self, "\(json)") { try decode(json) }
    }
    #expect(throws: Never.self) {
        try decode(#"{"match": "all", "rules": [\#(rule)], "limit": \#(limit)}"#)
    }
}

@Test func storedRulesRejectWhatCantBeCompiled() {
    for json in [
        #"{"match": "some", "rules": []}"#,
        #"{"match": "all", "rules": [{"field": "tempo", "comparison": "is", "value": "x"}]}"#,
        #"{"match": "all", "rules": [{"field": "title", "comparison": "greaterThan", "value": "a"}]}"#,
        #"{"match": "all", "rules": [{"field": "title", "comparison": "is", "value": 3}]}"#,
        #"{"match": "all", "rules": [{"field": "year", "comparison": "is", "value": "1990"}]}"#,
        #"{"match": "all", "rules": [{"field": "year", "comparison": "is", "value": -1}]}"#,
        #"{"match": "all", "rules": [{"field": "rating", "comparison": "is", "value": 6}]}"#,
        #"{"match": "all", "rules": [{"field": "year", "comparison": "is", "value": 1.5}]}"#,
        #"{"match": "all", "rules": [{"field": "dateAdded", "comparison": "is", "value": 3}]}"#,
        #"{"match": "all", "rules": [], "limit": {"count": 0, "order": "title"}}"#,
        #"{"match": "all", "rules": [], "limit": {"count": 5, "order": "random"}}"#,
        #"{"match": "all"}"#,
    ] {
        #expect(throws: DecodingError.self, "\(json)") { try decode(json) }
    }
}

@Test func everyFieldTakesEachOfItsComparisons() throws {
    let library = try TestLibrary()
    _ = try library.scan()
    let index = try library.index()
    for field in SmartField.allCases {
        for comparison in SmartComparison.comparisons(for: field.kind) {
            let value: SmartValue = field.kind == .text ? .text("a") : .number(1)
            let rule = SmartRule(field, comparison, value)
            #expect(rule.problem == nil)
            let id = try index.createPlaylist(
                named: "\(field) \(comparison)", rules: SmartRules(match: .all, rules: [rule]))
            #expect(throws: Never.self, "\(field) \(comparison)") {
                try index.trackIDs(TrackFilter(source: .playlist(id)), sortedBy: .title)
            }
        }
        for comparison in SmartComparison.allCases
        where !SmartComparison.comparisons(for: field.kind).contains(comparison) {
            #expect(SmartRule(field, comparison, .number(1)).problem != nil)
        }
    }
}

/// The paths of a smart playlist's tracks.
private func smartPaths(_ index: LibraryIndex, _ rules: SmartRules) throws -> Set<String> {
    let id = try index.createPlaylist(named: "smart", rules: rules)
    return Set(
        try index.paths(
            ids: try index.trackIDs(TrackFilter(source: .playlist(id)), sortedBy: .path)
        )
        .values)
}

@Test func textRulesIgnoreCaseAndAccentsAndMatchAnyOrAll() throws {
    let library = try TestLibrary()
    _ = try library.scan()
    let index = try library.index()
    let rows = try index.rows(ids: try index.trackIDs(sortedBy: .path))
    let artist = try #require(rows.compactMap(\.artist).first)
    let genre = try #require(rows.compactMap(\.genre).first { $0 != rows.first?.genre })
    let byArtist = Set(rows.filter { $0.artist == artist }.map(\.path))
    let byGenre = Set(rows.filter { $0.genre == genre }.map(\.path))

    #expect(
        try smartPaths(
            index, SmartRules(match: .all, rules: [.init(.artist, .is, .text(artist.uppercased()))])
        )
            == byArtist)
    let artistRule = SmartRule(.artist, .is, .text(artist))
    let genreRule = SmartRule(.genre, .is, .text(genre))
    #expect(
        try smartPaths(index, SmartRules(match: .any, rules: [artistRule, genreRule]))
            == byArtist.union(byGenre))
    #expect(
        try smartPaths(index, SmartRules(match: .all, rules: [artistRule, genreRule]))
            == byArtist.intersection(byGenre))
    #expect(
        try smartPaths(
            index, SmartRules(match: .all, rules: [.init(.artist, .isNot, .text(artist))]))
            == Set(rows.map(\.path)).subtracting(byArtist))
    #expect(try smartPaths(index, SmartRules(match: .all, rules: [])) == Set(rows.map(\.path)))
    // LIKE's wildcards are literal in what's typed.
    #expect(
        try smartPaths(
            index, SmartRules(match: .all, rules: [.init(.title, .contains, .text("%"))]))
            == Set(rows.filter { $0.title.contains("%") }.map(\.path)))
}

@Test func statsRulesAndALimitPickByPlays() throws {
    let library = try TestLibrary()
    _ = try library.scan()
    let index = try library.index()
    let ids = try index.trackIDs(sortedBy: .path)
    let paths = try index.rows(ids: ids).map(\.path)
    let now = Date().timeIntervalSince1970
    for (count, path) in paths.prefix(4).enumerated() {
        for _ in 0...count { try index.recordPlay(path, at: now - 86_400 * Double(count * 10)) }
    }
    try index.setRating(4, trackIDs: [ids[5]])

    #expect(
        try smartPaths(
            index, SmartRules(match: .all, rules: [.init(.playCount, .greaterThan, .number(1))]))
            == Set(paths[1...3]))
    #expect(
        try smartPaths(
            index,
            SmartRules(match: .all, rules: [], limit: SmartLimit(count: 2, order: .mostPlayed)))
            == Set(paths[2...3]))
    #expect(
        try smartPaths(
            index, SmartRules(match: .all, rules: [.init(.lastPlayed, .inLast, .number(15))]))
            == Set(paths[0...1]))
    #expect(
        try smartPaths(
            index, SmartRules(match: .all, rules: [.init(.lastPlayed, .notInLast, .number(15))]))
            == Set(paths).subtracting(paths[0...1]))
    #expect(
        try smartPaths(index, SmartRules(match: .all, rules: [.init(.rating, .is, .number(4))]))
            == [paths[5]])
}

@Test func aTrackWithoutAYearHasNoneToCompareOrSort() throws {
    let library = try TestLibrary()
    _ = try library.scan()
    let index = try library.index()
    let rows = try index.rows(ids: try index.trackIDs(sortedBy: .path))
    let untagged = Set(rows.filter { $0.year == nil }.map(\.path))
    try #require(!untagged.isEmpty, "the fixtures have tracks without a year")
    let early = try smartPaths(
        index, SmartRules(match: .all, rules: [.init(.year, .lessThan, .number(3000))]))
    #expect(early == Set(rows.map(\.path)).subtracting(untagged))
    // Untagged tracks sort first, ahead of every year.
    let sorted = try index.rows(ids: try index.trackIDs(sortedBy: .year))
    #expect(Set(sorted.prefix(untagged.count).map(\.path)) == untagged)
}

@Test func durationsCompareInWholeSeconds() throws {
    let library = try TestLibrary()
    _ = try library.scan()
    let index = try library.index()
    let rows = try index.rows(ids: try index.trackIDs(sortedBy: .path))
    let row = try #require(rows.first { $0.durationSeconds != $0.durationSeconds.rounded(.down) })
    let seconds = Int(row.durationSeconds)
    #expect(
        try smartPaths(
            index, SmartRules(match: .all, rules: [.init(.duration, .is, .number(seconds))]))
            == Set(rows.filter { Int($0.durationSeconds) == seconds }.map(\.path)))
}
