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
