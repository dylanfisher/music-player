import Library
import Testing

@testable import PlaylistEditor

@Test func aNewDraftHasOneEmptyRuleThatMatchesEverything() throws {
    let draft = RuleDraft(name: "New", rules: nil)
    #expect(draft.rows.count == 1)
    #expect(
        try draft.rules() == SmartRules(match: .all, rules: [.init(.title, .contains, .text(""))]))
}

@Test func aDraftReadsBackTheRulesItStartedFrom() throws {
    let rules = SmartRules(
        match: .any,
        rules: [
            .init(.artist, .startsWith, .text("The")), .init(.lastPlayed, .notInLast, .number(30)),
        ],
        limit: SmartLimit(count: 10, order: .leastPlayed))
    let draft = RuleDraft(name: "Old", rules: rules)
    #expect(draft.rows.map(\.value) == ["The", "30"])
    #expect(draft.isLimited && draft.limitCount == "10")
    #expect(try draft.rules() == rules)
}

@Test func changingAFieldKeepsWhatStillFitsAndClearsWhatDoesnt() {
    var draft = RuleDraft(name: "x", rules: nil)
    draft.setComparison(.startsWith, at: 0)
    draft.setValue("abc", at: 0)
    draft.setField(.album, at: 0)
    #expect(draft.rows[0] == .init(field: .album, comparison: .startsWith, value: "abc"))
    draft.setField(.year, at: 0)
    #expect(draft.rows[0] == .init(field: .year, comparison: .is, value: ""))
    draft.setValue("1999", at: 0)
    draft.setComparison(.greaterThan, at: 0)
    draft.setField(.playCount, at: 0)
    #expect(draft.rows[0] == .init(field: .playCount, comparison: .greaterThan, value: "1999"))
    draft.setField(.dateAdded, at: 0)
    #expect(draft.rows[0] == .init(field: .dateAdded, comparison: .inLast, value: "1999"))
}

@Test func rowsAreAddedAfterOneAndTheLastStays() {
    var draft = RuleDraft(name: "x", rules: nil)
    draft.setValue("first", at: 0)
    draft.addRow(after: 0)
    draft.addRow(after: 0)
    draft.setValue("second", at: 1)
    #expect(draft.rows.map(\.value) == ["first", "second", ""])
    draft.removeRow(at: 0)
    draft.removeRow(at: 0)
    draft.removeRow(at: 0)
    #expect(draft.rows.map(\.value) == [""])
}

@Test func whatCantBeSavedNamesItsRule() throws {
    var draft = RuleDraft(name: "  ", rules: nil)
    #expect(throws: RuleDraft.Problem(description: "Give the playlist a name.")) {
        try draft.checkedName()
    }
    draft.name = " Mix "
    #expect(try draft.checkedName() == "Mix")
    draft.addRow(after: 0)
    draft.setField(.rating, at: 1)
    draft.setValue("2.5", at: 1)
    #expect(throws: RuleDraft.Problem(description: "Rule 2 needs a whole number.")) {
        try draft.rules()
    }
    draft.setValue("9", at: 1)
    #expect(throws: RuleDraft.Problem(description: "Rule 2: a rating is 0 to 5 stars, not 9.")) {
        try draft.rules()
    }
    draft.setValue("4", at: 1)
    draft.isLimited = true
    draft.limitCount = "0"
    #expect(throws: RuleDraft.Problem(description: "The limit needs a number of tracks above 0.")) {
        try draft.rules()
    }
    draft.limitCount = "5"
    #expect(try draft.rules().limit == SmartLimit(count: 5, order: .mostPlayed))
}
