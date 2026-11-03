import AppKit
import Testing

@testable import NowPlaying
@testable import Settings

@MainActor @Test func theMinimalStylePutsTheTrackOnOneLineAndTheTallOneOnTwo() throws {
    let parts = StatusBarParts()
    parts.show(title: "Come Together", subtitle: "The Beatles — Abbey Road")
    #expect(parts.trackText == "Come Together — The Beatles — Abbey Road")
    parts.apply(.tall)
    #expect(parts.trackText == "Come Together")
    let track = try #require(parts.view(for: .track) as? NSStackView)
    #expect(track.arrangedSubviews.filter { !$0.isHidden }.count == 2)
    parts.apply(.minimal)
    #expect(track.arrangedSubviews.filter { !$0.isHidden }.count == 1)
    parts.show(title: "Not Playing", subtitle: "")
    #expect(parts.trackText == "Not Playing")
}

@MainActor @Test func everyPartButTheTotalsIsAViewOfItsOwn() {
    let parts = StatusBarParts()
    let views = StatusPart.allCases.compactMap { parts.view(for: $0) }
    #expect(views.count == StatusPart.allCases.count - 1)
    #expect(Set(views.map(ObjectIdentifier.init)).count == views.count)
    #expect(parts.view(for: .totals) == nil)
}
