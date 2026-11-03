import AppKit
import Testing

@testable import LibraryBrowser

/// `color` as `appearance` draws it.
@MainActor
private func color(_ color: NSColor, in appearance: NSAppearance.Name) throws -> NSColor {
    var resolved = color
    try #require(NSAppearance(named: appearance)).performAsCurrentDrawingAppearance {
        resolved = color.usingColorSpace(.sRGB) ?? color
    }
    return resolved
}

@MainActor @Test func aSystemBackgroundIsHeldResolvedAndFollowsTheAppearance() throws {
    let table = KeyTableView()
    table.appearance = NSAppearance(named: .aqua)
    table.backgroundColor = .controlBackgroundColor
    #expect(table.backgroundColor.type == .componentBased)
    #expect(table.backgroundColor == (try color(.controlBackgroundColor, in: .aqua)))

    table.appearance = NSAppearance(named: .darkAqua)
    #expect(table.backgroundColor == (try color(.controlBackgroundColor, in: .darkAqua)))
}

@MainActor @Test func aResolvedBackgroundSetBackKeepsFollowingTheAppearance() throws {
    let table = KeyTableView()
    table.appearance = NSAppearance(named: .aqua)
    table.backgroundColor = .controlBackgroundColor
    // As Glass does: clear while it shows, then the color it replaced, put back after the
    // appearance changed.
    let replaced = table.backgroundColor
    table.backgroundColor = .clear
    table.appearance = NSAppearance(named: .darkAqua)
    #expect(table.backgroundColor.alphaComponent == 0)
    table.backgroundColor = replaced
    #expect(table.backgroundColor == (try color(.controlBackgroundColor, in: .darkAqua)))

    table.backgroundColor = .systemRed
    table.appearance = NSAppearance(named: .aqua)
    #expect(table.backgroundColor == (try color(.systemRed, in: .aqua)))
}
