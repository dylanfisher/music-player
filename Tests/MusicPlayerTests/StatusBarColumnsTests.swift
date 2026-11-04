import AppKit
import Testing

@testable import LibraryBrowser
@testable import MusicPlayer
@testable import Settings

/// `view`'s frame in window coordinates.
@MainActor
private func frame(_ view: NSView?) throws -> NSRect {
    let view = try #require(view)
    return view.convert(view.bounds, to: nil)
}

/// The default is the bar as it was before columns: the totals alone, their label stretched
/// across a middle centered on the window up to the room beside the nearer edge, its text
/// centered, at the track table header's height (ADR 0084, 0085).
@MainActor @Test func theDefaultLayoutIsTheBarAsItWas() async throws {
    let fixture = try await MainWindowFixture()
    defer { fixture.close() }
    let browser = fixture.browser
    let center = try #require(browser.statusColumn(at: .center))
    #expect(center.stack.arrangedSubviews == [browser.statusLabel])
    #expect(browser.statusColumn(at: .leading(0)) == nil)
    #expect(browser.statusColumn(at: .trailing(0)) == nil)
    #expect(browser.statusLabel.alignment == .center)
    #expect(!browser.statusLabel.isHidden)
    let header = try #require(browser.table.table.headerView)
    #expect(browser.statusArea.frame.height == header.frame.height)
    let middle = try frame(center)
    #expect(try frame(center.stack) == middle)
    let row = try frame(browser.statusArea)
    let window = try #require(fixture.window.window.contentView).bounds
    #expect(abs(middle.midX - window.midX) <= 0.5)
    // The row's inset, and the spacing beside the empty scan progress.
    let room = 2 * LibraryBrowser.statusSpacingPoints
    let nearer = min(middle.minX - row.minX, row.maxX - middle.maxX)
    #expect(abs(nearer - room) <= 0.5, "\(middle) in \(row)")
}

/// A fixed leading column keeps its width and alignment, the flexible center and trailing
/// columns share the rest equally, and the center stays on the window's center line.
@MainActor @Test func columnsKeepTheirWidthsAndAlignmentAroundTheCenter() async throws {
    let fixture = try await MainWindowFixture()
    defer { fixture.close() }
    fixture.window.window.setFrame(
        NSRect(origin: fixture.window.window.frame.origin, size: NSSize(width: 1440, height: 900)),
        display: false)
    let layout = BarLayout<StatusPart>(
        leading: [BarColumn(parts: [.art, .track], width: .fixed(220), alignment: .leading)],
        center: BarColumn(parts: [.seek], width: .flexible, alignment: .center),
        trailing: [BarColumn(parts: [.format], width: .flexible, alignment: .trailing)])
    fixture.setLayout(layout)
    let browser = fixture.browser
    let leading = try frame(browser.statusColumn(at: .leading(0)))
    let center = try frame(browser.statusColumn(at: .center))
    let trailing = try frame(browser.statusColumn(at: .trailing(0)))
    let window = try #require(fixture.window.window.contentView).bounds
    #expect(leading.width == 220)
    #expect(abs(center.midX - window.midX) <= 0.5, "\(center) in \(window)")
    #expect(abs(center.width - trailing.width) <= 1, "\(center) and \(trailing)")
    #expect(trailing.minX >= center.maxX)
    // The leading column's parts sit at its left, the trailing one's at its right.
    let leadingParts = try frame(browser.statusColumn(at: .leading(0))?.stack)
    let trailingParts = try frame(browser.statusColumn(at: .trailing(0))?.stack)
    #expect(leadingParts.minX == leading.minX && leadingParts.width < leading.width)
    #expect(trailingParts.maxX == trailing.maxX && trailingParts.width < trailing.width)
    // The seek bar stretches across its column.
    #expect(try frame(browser.statusColumn(at: .center)?.stack).width == center.width)
}

/// In the tall style a stacked column puts its parts one over another and the bar grows to
/// fit them; in the minimal one they sit side by side at the header's height.
@MainActor @Test func aStackedColumnGrowsTheTallBar() async throws {
    let fixture = try await MainWindowFixture()
    defer { fixture.close() }
    let layout = BarLayout<StatusPart>(
        leading: [BarColumn(parts: [.art], width: .flexible, alignment: .leading)],
        center: BarColumn(
            parts: [.track, .format, .seek], width: .fixed(300), alignment: .leading, stacks: true))
    let browser = fixture.browser
    let header = try #require(browser.table.table.headerView).frame.height
    fixture.setLayout(layout, style: .minimal)
    let center = try #require(browser.statusColumn(at: .center))
    #expect(center.stack.orientation == .horizontal)
    #expect(browser.statusArea.frame.height == header)

    fixture.setLayout(layout, style: .tall)
    #expect(center.stack.orientation == .vertical)
    let height = browser.statusArea.frame.height
    #expect(height > StatusBarStyle.tallPoints && height <= StatusBarStyle.tallMaxPoints)
    // The totals' label is last, hidden until something fails.
    let views = center.stack.arrangedSubviews
    #expect(views.last == browser.statusLabel && browser.statusLabel.isHidden)
    let frames = try views.map(frame)
    #expect(frames[0].minY > frames[1].minY && frames[1].minY > frames[2].minY, "\(frames)")
    // The seek bar takes the column's width, and the art the bar's height.
    #expect(frames[2].width == 300)
    let art = try #require(fixture.nowPlaying.statusBar.view(for: .art))
    #expect(abs(art.frame.height - (height - 2 * StatusBarLayout.artInsetPoints)) < 0.01)
    let scroll = try #require(browser.table.view as? NSScrollView)
    #expect(scroll.contentInsets.bottom == height)
}

/// A failure shown in a stacked column, which holds the totals' label for it, adds a line, and
/// the bar and the lists' inset grow with it.
@MainActor @Test func aFailureInAStackedColumnGrowsTheBar() async throws {
    let fixture = try await MainWindowFixture()
    defer { fixture.close() }
    fixture.setLayout(
        BarLayout(
            center: BarColumn(
                parts: [.track], width: .fixed(300), alignment: .leading, stacks: true)),
        style: .tall)
    let browser = fixture.browser
    let scroll = try #require(browser.table.view as? NSScrollView)
    let before = browser.statusArea.frame.height
    browser.report("the disk went away")
    fixture.window.window.layoutIfNeeded()
    let after = browser.statusArea.frame.height
    #expect(after > before, "\(before) then \(after)")
    #expect(scroll.contentInsets.bottom == after)
}

/// A stack taller than the cap leaves the bar at the cap, cut at its edges.
@MainActor @Test func aStackTallerThanTheCapIsClipped() async throws {
    let fixture = try await MainWindowFixture()
    defer { fixture.close() }
    fixture.setLayout(
        BarLayout(
            center: BarColumn(
                parts: [.track, .format, .seek, .totals], width: .fixed(300), alignment: .leading,
                stacks: true)),
        style: .tall)
    let browser = fixture.browser
    let stack = try #require(browser.statusColumn(at: .center)?.stack)
    #expect(
        stack.fittingSize.height + 2 * StatusBarLayout.artInsetPoints > StatusBarStyle.tallMaxPoints
    )
    #expect(abs(browser.statusArea.frame.height - StatusBarStyle.tallMaxPoints) < 0.01)
    if #available(macOS 14, *) { #expect(browser.statusArea.clipsToBounds) }
}
