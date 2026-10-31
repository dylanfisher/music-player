import AppKit
import Settings
import Testing

@testable import MusicPlayer

/// Column spacing and a vertical scroller, which the table adds to its columns' widths.
private let tableExtraPoints = 6.0 + 15.0

@MainActor @Test func theDefaultColumnsFitBesideTheSidebarAndQueue() {
    let settings = AppSettings()
    let columns = settings.trackTable.defaultValue.columns
    let needed = columns.reduce(0) { $0 + $1.width + 6 } + tableExtraPoints
    let room =
        Double(MainWindow.defaultSize.width) - Double(settings.sidebarWidth.defaultValue)
        - Double(settings.queueWidth.defaultValue)
    #expect(needed <= room)
}

@Test func aFrameOnADisplayThatsGoneIsCentered() {
    let screen = NSRect(x: 0, y: 0, width: 1440, height: 875)
    let onScreen = WindowFrame(x: 100, y: 50, width: 1280, height: 760)
    #expect(
        restoredFrame(onScreen, screens: [screen])
            == NSRect(x: 100, y: 50, width: 1280, height: 760))
    // It was on a second display to the right.
    #expect(
        restoredFrame(WindowFrame(x: 1600, y: 0, width: 800, height: 600), screens: [screen]) == nil
    )
    #expect(restoredFrame(nil, screens: [screen]) == nil)
}

@Test func dividersKeepTheSidebarAndQueueInRange() {
    #expect(dividerLimits(0, width: 1000) == 100...600)
    // The queue's divider sits between 1000 points and 150 from the right edge.
    #expect(dividerLimits(1, width: 1200) == 200...1050)
    #expect(dividerLimits(1, width: 800) == -200...650)
}
