import Foundation
import Settings
import Testing

@testable import Library
@testable import LibraryBrowser

@MainActor @Test func watcherEventsArriveInTheOrderSent() async throws {
    let databaseURL = try browserLibrary.get().databaseURL
    let browser = LibraryBrowser(
        reader: try LibraryReader(databaseURL: databaseURL),
        index: try LibraryIndex(at: databaseURL), layout: AppState().trackTable.defaultValue,
        browserHeight: 100, folders: [])
    let send = browser.watcherEvents
    let folders = (0..<200).map { "/Music/\($0)" }
    // From another thread, as the watcher sends them: each folder's progress, then its outcome.
    await Task.detached {
        for folder in folders {
            send(.scanning(folder: folder, ScanProgress()))
            send(.scanned(folder: folder, ScanSummary()))
        }
        send(.scanning(folder: "/Music/last", ScanProgress()))
    }.value
    let deadline = Date().addingTimeInterval(10)
    while browser.status.scanning["/Music/last"] == nil, Date() < deadline {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(Array(browser.status.scanning.keys) == ["/Music/last"])
}
