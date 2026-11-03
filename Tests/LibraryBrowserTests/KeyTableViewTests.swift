import AppKit
import Testing

@testable import LibraryBrowser

/// `color` as `appearance` draws it.
@MainActor
private func resolved(_ color: NSColor, in appearance: NSAppearance.Name) throws -> NSColor {
    var resolved = color
    try #require(NSAppearance(named: appearance)).performAsCurrentDrawingAppearance {
        resolved = color.usingColorSpace(.sRGB) ?? color
    }
    return resolved
}

@MainActor @Test func aSystemBackgroundIsHeldResolvedAndFollowsTheAppearance() throws {
    let table = KeyTableView()
    for appearance: NSAppearance.Name in [
        .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
    ] {
        table.appearance = NSAppearance(named: appearance)
        table.backgroundColor = .controlBackgroundColor
        #expect(table.backgroundColor.type == .componentBased)
        #expect(table.backgroundColor == (try resolved(.controlBackgroundColor, in: appearance)))
        #expect(table.backgroundAsSet == .controlBackgroundColor)
    }
    table.appearance = NSAppearance(named: .aqua)
    #expect(table.backgroundColor == (try resolved(.controlBackgroundColor, in: .aqua)))
}
