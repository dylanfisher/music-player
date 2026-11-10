import Foundation
import Testing

@testable import Settings

private let schema = AppSettings()

private func format(_ shown: StatusTotals) -> Setting<TotalsTemplate> {
    switch shown {
    case .listAndSelection: schema.totalsListAndSelectionFormat
    case .list: schema.totalsListFormat
    case .selection: schema.totalsSelectionFormat
    }
}

/// Each default is the bar's text before the templates: the list's totals, and the
/// selection's after them, alone or not at all, as the click chose.
@Test func theDefaultsAreTheBarsTotals() {
    #expect(schema.totalsFormat.defaultValue.template == "{tracks}, {size}, {duration}")
    #expect(
        format(.listAndSelection).defaultValue.template
            == "{tracks}, {size}, {duration}"
            + " ({selectedTracks} selected, {selectedSize}, {selectedDuration})")
    #expect(format(.list).defaultValue.template == "{tracks}, {size}, {duration}")
    #expect(
        format(.selection).defaultValue.template
            == "{selectedTracks} selected, {selectedSize}, {selectedDuration}")
    for shown in StatusTotals.allCases {
        #expect(format(shown).defaultValue.problem() == nil)
        #expect(format(shown).title.hasSuffix(shown.title))
    }
}

@Test func everyTotalIsAToken() {
    #expect(
        TotalsTemplate("{albums} · {selectedAlbums} · {missing}").parts == [
            .token(.albums), .text(" · "), .token(.selectedAlbums), .text(" · "),
            .token(.missing),
        ])
}

/// A title token isn't a total, and the problem lists the totals' tokens, as the banner shows
/// it for the config file and the settings window under the field.
@Test func aTemplateWithATitleTokenIsRefused() throws {
    let found = try #require(TotalsTemplate("{tracks} by {artist}").problem())
    #expect(found.hasPrefix("no token {artist}"), "\(found)")
    for token in TotalsToken.allCases { #expect(found.contains(token.placeholder)) }
    guard case .failure(.invalid(let reason)) = schema.totalsFormat.decode(json: "{title}")
    else {
        Issue.record("accepted {title}")
        return
    }
    #expect(reason.hasPrefix("no token {title}"))
    #expect(
        TotalsTemplate(" ").problem()
            == "empty; write a template such as {tracks}, {size}, {duration}")
}

@Test func theTotalsKindCarriesItsTokens() {
    guard case .template(let tokens) = schema.totalsSelectionFormat.kind else {
        Issue.record("\(schema.totalsSelectionFormat.kind)")
        return
    }
    #expect(tokens.map(\.name) == TotalsToken.allCases.map { "{\($0.rawValue)}" })
    #expect(Set(tokens.map(\.help)).count == tokens.count)
}
