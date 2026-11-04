import AppKit
import Testing

@testable import Library
@testable import LibraryBrowser
@testable import MusicPlayer
@testable import Settings

/// The status bar's middle, which holds the parts, its center in window coordinates and the
/// window's center.
@MainActor
private func centers(_ fixture: MainWindowFixture) throws -> (middle: CGFloat, window: CGFloat) {
    fixture.window.window.layoutIfNeeded()
    let middle = try #require(fixture.browser.statusColumn(at: .center)?.stack)
    let content = try #require(fixture.window.window.contentView)
    return (middle.convert(middle.bounds, to: nil).midX, content.bounds.midX)
}

/// The middle stays on the window's center line, under the title, as the scan progress shows
/// and the sidebar resizes, hides and shows (ADR 0084).
@MainActor @Test(arguments: [[StatusPart.seek, .totals], [.art, .track, .format]])
func theStatusBarsMiddleStaysCenteredOnTheWindow(_ parts: [StatusPart]) async throws {
    let fixture = try await MainWindowFixture(statusBar: .centered(parts))
    defer { fixture.close() }
    var ancestor = fixture.browser.sidebar.view.superview
    while let view = ancestor, !(view is NSSplitView) { ancestor = view.superview }
    let sidebarSplit = try #require(ancestor as? NSSplitView)
    let changes: [(String, () -> Void)] = [
        ("as built", {}),
        (
            "scanning",
            {
                var progress = ScanProgress()
                progress.found = 1234
                fixture.browser.libraryChanged(.scanning(folder: "/music", progress))
            }
        ),
        ("a wider sidebar", { sidebarSplit.setPosition(300, ofDividerAt: 0) }),
        ("the sidebar hidden", { fixture.window.toggleSidebar() }),
        ("the sidebar shown", { fixture.window.toggleSidebar() }),
        ("the queue hidden", { fixture.window.toggleQueue() }),
    ]
    for (what, change) in changes {
        change()
        let (middle, window) = try centers(fixture)
        #expect(abs(middle - window) <= 0.5, "\(what): \(middle) against \(window)")
    }
}

/// No status bar part, alone or with the others, in either style, changes the window's frame or
/// moves a split's divider, at the default size, at the window's narrowest and at the 2015
/// MacBook Pro's screen size, with every panel open, a scan's text and the problems button.
/// Before, Art alone left nothing in the bar that could stretch, and the bar's stacks held the
/// window to the art's width.
@MainActor
@Test(arguments: [nil, NSSize(width: 720, height: 600), NSSize(width: 1440, height: 900)])
func noStatusBarPartResizesTheWindowOrItsSplits(_ size: NSSize?) async throws {
    let fixture = try await MainWindowFixture()
    defer { fixture.close() }
    let window = fixture.window
    if let size {
        window.window.setFrame(
            NSRect(origin: window.window.frame.origin, size: size), display: false)
        if !window.isSignalPathVisible { window.toggleSignalPath() }
        if !window.isSidebarVisible { window.toggleSidebar() }
        if !window.isQueueVisible { window.toggleQueue() }
        if !fixture.browser.isBrowserVisible { fixture.browser.toggleBrowser() }
        fixture.browser.libraryChanged(.scanFailed(folder: "/elsewhere", reason: "gone"))
        var progress = ScanProgress()
        progress.found = 12345
        fixture.browser.libraryChanged(
            .scanning(folder: "/music/a folder with a long name of its own", progress))
        #expect(fixture.browser.problemsButtonTitle != nil)
        try await Task.sleep(nanoseconds: 500_000_000)
        window.window.layoutIfNeeded()
        #expect(window.window.frame.size == size)
    }
    let layout = fixture.layout
    let sets = StatusPart.allCases.map { [$0] } + [StatusPart.allCases, []]
    for style in StatusBarStyle.allCases {
        for parts in sets + sets.reversed() {
            fixture.setParts(parts, style: style)
            #expect(
                fixture.layout == layout,
                "\(parts) \(style): \(zip(fixture.layout, layout).filter { $0 != $1 })")
        }
    }
    // Columns too: the widest fixed ones, flexible ones beside a fixed center, stacks.
    let columns = [
        BarLayout<StatusPart>(
            leading: [BarColumn(parts: [.art, .track], width: .fixed(1200), alignment: .leading)],
            center: BarColumn(parts: [.seek], width: .fixed(1200), alignment: .center),
            trailing: [BarColumn(parts: [.format], width: .fixed(1200), alignment: .trailing)]),
        BarLayout(
            leading: [BarColumn(parts: [.seek], width: .flexible, alignment: .leading)],
            center: BarColumn(parts: [.art], width: .fixed(16), alignment: .center),
            trailing: [
                BarColumn(
                    parts: [.track, .format, .totals], width: .flexible, alignment: .trailing,
                    stacks: true)
            ]),
    ]
    for style in StatusBarStyle.allCases {
        for statusBar in columns {
            fixture.setLayout(statusBar, style: style)
            #expect(
                fixture.layout == layout,
                "\(statusBar) \(style): \(zip(fixture.layout, layout).filter { $0 != $1 })")
        }
    }
    fixture.window.toggleStatusBar()
    #expect(fixture.layout == layout, "hidden")
    fixture.window.toggleStatusBar()
    #expect(fixture.layout == layout, "shown")
}

/// The bar lies over the bottom of the track table, which scrolls its last rows clear of it,
/// and gives the space back when hidden.
@MainActor @Test func theTrackTableScrollsUnderTheStatusBar() async throws {
    let fixture = try await MainWindowFixture()
    defer { fixture.close() }
    let browser = fixture.browser
    let scroll = try #require(browser.table.view as? NSScrollView)
    let area = browser.statusArea
    #expect(area.frame.height > 0)
    #expect(scroll.contentInsets.bottom == area.frame.height)
    let bar = area.convert(area.bounds, to: nil)
    let list = scroll.convert(scroll.bounds, to: nil)
    #expect(bar.minY == list.minY, "the rows reach the window's bottom, under the bar")
    if #available(macOS 26, *) { #expect(area is NSGlassEffectView) }
    fixture.window.toggleStatusBar()
    #expect(scroll.contentInsets.bottom == 0)
    fixture.window.toggleStatusBar()
    fixture.setParts([.art], style: .tall)
    #expect(
        Double(scroll.contentInsets.bottom) == StatusBarLayout.tallPoints,
        "\(scroll.contentInsets) \(area.frame)")
}

/// The scroller stops at the bar, the header keeps its inset, and a list scrolled to its end
/// keeps its last row clear of the bar as the bar grows taller.
@MainActor @Test func theTrackTablesScrollerAndLastRowStayClearOfTheStatusBar() async throws {
    let fixture = try await MainWindowFixture()
    defer { fixture.close() }
    let browser = fixture.browser
    let table = browser.table.table
    let scroll = try #require(table.enclosingScrollView)
    let clip = scroll.contentView
    let header = try #require(table.headerView)
    #expect(clip.contentInsets.top == header.frame.height)
    let scroller = try #require(scroll.verticalScroller)
    let area = browser.statusArea
    #expect(
        scroller.convert(scroller.bounds, to: nil).minY == area.convert(area.bounds, to: nil).maxY)

    let last = table.numberOfRows - 1
    #expect(table.rect(ofRow: last).maxY > clip.bounds.height, "the rows fit, nothing to scroll")
    table.scrollRowToVisible(last)
    for style in [StatusBarStyle.tall, .minimal, .tall] {
        fixture.setParts([.art], style: style)
        #expect(
            table.rect(ofRow: last).maxY == clip.bounds.maxY - clip.contentInsets.bottom,
            "\(style): \(table.rect(ofRow: last)) in \(clip.bounds), \(clip.contentInsets)")
    }
    // Scrolled up a row, the list stays where it is.
    browser.table.scroll(byRows: -1)
    let top = clip.bounds.minY
    fixture.setParts([.art], style: .minimal)
    #expect(clip.bounds.minY == top)
    #expect(clip.contentInsets.top == header.frame.height)
}
