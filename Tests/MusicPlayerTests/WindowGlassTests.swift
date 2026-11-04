import AppKit
import Testing

@testable import LibraryBrowser
@testable import MusicPlayer

@MainActor @Test func theGlassClearsTheListsAndPutsThemBack() {
    let table = NSTableView()
    table.usesAlternatingRowBackgroundColors = true
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
    column.title = "Title"
    table.addTableColumn(column)
    let header = column.headerCell
    let scroll = NSScrollView()
    scroll.documentView = table
    let outline = NSOutlineView()
    let outlineScroll = NSScrollView()
    outlineScroll.documentView = outline
    let bar = NSVisualEffectView()
    bar.blendingMode = .withinWindow
    let content = NSStackView(views: [scroll, outlineScroll, bar])
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let glass = WindowGlass(window: window, content: content)
    let color = table.backgroundColor

    glass.set(true)
    #expect(window.styleMask.contains(.fullSizeContentView))
    #expect(window.titlebarAppearsTransparent)
    #expect(table.backgroundColor == .clear)
    #expect(!table.usesAlternatingRowBackgroundColors)
    #expect(!scroll.drawsBackground)
    // Rows scroll under the status bar, which blends with them (ADR 0084).
    #expect(bar.blendingMode == .withinWindow)
    #expect(column.headerCell is ClearHeaderCell)
    #expect(column.headerCell.stringValue == "Title")
    // The sidebar's outline is left on its own material.
    #expect(outlineScroll.drawsBackground)
    #expect(outline.backgroundColor != .clear)

    glass.set(false)
    #expect(!window.styleMask.contains(.fullSizeContentView))
    #expect(!window.titlebarAppearsTransparent)
    #expect(table.backgroundColor == color)
    #expect(table.usesAlternatingRowBackgroundColors)
    #expect(scroll.drawsBackground)
    #expect(bar.blendingMode == .withinWindow)
    #expect(column.headerCell === header)
}

/// `color` as `appearance` draws it.
@MainActor
private func resolved(_ color: NSColor, in appearance: NSAppearance.Name) throws -> NSColor {
    var resolved = color
    try #require(NSAppearance(named: appearance)).performAsCurrentDrawingAppearance {
        resolved = color.usingColorSpace(.sRGB) ?? color
    }
    return resolved
}

@MainActor @Test func aTrackListGlassPutsBackFollowsTheAppearance() throws {
    let browser = KeyTableView()
    let scroll = NSScrollView()
    scroll.documentView = browser
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let glass = WindowGlass(window: window, content: scroll)
    window.appearance = NSAppearance(named: .accessibilityHighContrastAqua)
    browser.backgroundColor = .controlBackgroundColor

    glass.set(true)
    window.appearance = NSAppearance(named: .accessibilityHighContrastDarkAqua)
    glass.set(false)
    // The system color itself comes back, not the color it resolved to when the glass went on.
    #expect(browser.backgroundAsSet == .controlBackgroundColor)
    #expect(
        browser.backgroundColor
            == (try resolved(.controlBackgroundColor, in: .accessibilityHighContrastDarkAqua)))
    window.appearance = NSAppearance(named: .aqua)
    #expect(browser.backgroundColor == (try resolved(.controlBackgroundColor, in: .aqua)))
}

/// Glass turned on and off leaves the window as a fresh one draws it (ADR 0084). Before, the
/// style mask changed with it: the frame shrank by the toolbar and grew back, and the splits
/// shared that out, moving their dividers off the pixel grid.
/// In light and dark, with the user's alternating rows on and off.
@MainActor @Test(arguments: [NSAppearance.Name.aqua, .darkAqua], [true, false])
func glassOnThenOffLeavesTheWindowAsAFreshOne(
    _ appearance: NSAppearance.Name, alternating: Bool
) async throws {
    func table(glass: Bool, alternating: Bool = alternating) -> TableAppearance {
        TableAppearance(
            columnLines: false, rowLines: false, albumLines: false, rowLineColor: nil,
            albumLineColor: nil, alternatingRows: alternating,
            rowHeight: .regular, artSize: .fit, glass: glass)
    }
    let fresh = try await MainWindowFixture()
    defer { fresh.close() }
    let toggled = try await MainWindowFixture()
    defer { toggled.close() }
    for fixture in [fresh, toggled] {
        fixture.window.window.appearance = NSAppearance(named: appearance)
        fixture.browser.setTableAppearance(table(glass: false))
        fixture.window.window.displayIfNeeded()
    }
    #expect(toggled.layout == fresh.layout)
    // Alternating turned on and back as the user had it while on glass, so the translucent
    // rows come and go there too.
    let steps = [(true, true), (true, alternating), (false, alternating)]
    for (on, rowsAlternate) in steps + steps {
        toggled.window.setGlass(on)
        toggled.browser.setTableAppearance(table(glass: on, alternating: rowsAlternate))
        toggled.window.window.displayIfNeeded()
        toggled.window.window.layoutIfNeeded()
        #expect(toggled.layout == fresh.layout, "glass \(on)")
    }
    for window in [fresh.window.window, toggled.window.window] { window.displayIfNeeded() }
    #expect(fresh.tableLooks.contains { !$0.hasSuffix("row views []") }, "no row views to compare")
    #expect(
        toggled.tableLooks == fresh.tableLooks,
        "\(zip(toggled.tableLooks, fresh.tableLooks).filter { $0 != $1 })")
    #expect(toggled.window.window.styleMask == fresh.window.window.styleMask)
    #expect(!toggled.window.window.titlebarAppearsTransparent)
}

/// Glass in a zoomed window keeps it zoomed.
@MainActor @Test func glassKeepsAZoomedWindowZoomed() async throws {
    let fixture = try await MainWindowFixture()
    defer { fixture.close() }
    let window = fixture.window.window
    window.zoom(nil)
    #expect(window.isZoomed)
    let zoomed = window.frame
    for on in [true, false] {
        fixture.window.setGlass(on)
        #expect(window.isZoomed, "glass \(on)")
        #expect(window.frame == zoomed, "glass \(on)")
    }
}

/// Putting the frame and the dividers back after a glass change saves the layout as it was.
@MainActor @Test func glassLeavesTheSavedLayoutAsItWas() async throws {
    let fixture = try await MainWindowFixture()
    defer { fixture.close() }
    func saved() -> String {
        fixture.saver.flush()
        let state = fixture.state
        return "\(String(describing: state[\.windowFrame])) \(state[\.sidebarWidth]) "
            + "\(state[\.queueWidth]) \(state[\.browserHeight])"
    }
    let before = saved()
    for on in [true, false, true, false] {
        fixture.window.setGlass(on)
        #expect(saved() == before, "glass \(on)")
    }
}

/// On glass a list's header lets the glass through, a light tint under its titles, in light
/// and dark; the header, with a menu set meanwhile, comes back after.
@MainActor @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
func theGlassShowsThroughTheHeaders(_ appearance: NSAppearance.Name) throws {
    let table = NSTableView()
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
    column.title = "Title"
    column.width = 100
    table.addTableColumn(column)
    let scroll = NSScrollView()
    scroll.documentView = table
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.appearance = NSAppearance(named: appearance)
    let glass = WindowGlass(window: window, content: scroll)
    let header = try #require(table.headerView)
    header.menu = NSMenu(title: "Columns")
    window.layoutIfNeeded()

    glass.set(true)
    let shown = try #require(table.headerView)
    #expect(shown is GlassHeaderView)
    #expect(shown.menu === header.menu)
    window.layoutIfNeeded()
    let image = try #require(shown.bitmapImageRepForCachingDisplay(in: shown.bounds))
    shown.cacheDisplay(in: shown.bounds, to: image)
    // Past the column, and over the column away from its title.
    for x in [image.pixelsWide - 4, 4] {
        let alpha = try #require(image.colorAt(x: x, y: 4)?.alphaComponent)
        #expect(alpha > 0 && alpha <= 0.1, "\(x): \(alpha)")
    }

    // A column shown from the header's menu while the glass is on is cleared too.
    let added = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("artist"))
    added.title = "Artist"
    added.width = 100
    let stock = added.headerCell
    table.addTableColumn(added)
    window.layoutIfNeeded()
    let again = try #require(shown.bitmapImageRepForCachingDisplay(in: shown.bounds))
    shown.cacheDisplay(in: shown.bounds, to: again)
    #expect(added.headerCell is ClearHeaderCell)
    let overAdded =
        Int(shown.headerRect(ofColumn: 1).minX + 4) * again.pixelsWide
        / Int(shown.bounds.width)
    let alpha = try #require(again.colorAt(x: overAdded, y: 4)?.alphaComponent)
    #expect(alpha > 0 && alpha <= 0.1, "\(alpha)")

    let menu = NSMenu(title: "Other Columns")
    shown.menu = menu
    glass.set(false)
    #expect(table.headerView === header)
    #expect(header.menu === menu)
    #expect(added.headerCell === stock)
}
