import AppKit
import Testing

@testable import LibraryBrowser

/// The marked row's highlight is lighter than the selection color at 0.4, which hid its text,
/// and still clearly stronger than the hovered row's.
@MainActor @Test func theMarkedRowIsHighlightedLightly() throws {
    let list = StatsListView()
    list.rows = [StatsListView.Row(rank: nil, name: "", value: "", fraction: 0)]
    list.frame = NSRect(x: 0, y: 0, width: 200, height: StatsListView.rowHeightPoints)
    list.marked = 0
    let bitmap = try #require(list.bitmapImageRepForCachingDisplay(in: list.bounds))
    list.cacheDisplay(in: list.bounds, to: bitmap)
    // The middle of the row, clear of the bar along its bottom.
    let scale = CGFloat(bitmap.pixelsWide) / list.bounds.width
    let alpha = try #require(
        bitmap.colorAt(x: Int(100 * scale), y: Int(6 * scale))?.alphaComponent)
    #expect(alpha < 0.35)
    #expect(alpha > StatsListView.hoveredAlpha + 0.05)
}
