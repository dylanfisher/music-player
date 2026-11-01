import AppKit
import Settings
import Testing

@testable import Library
@testable import LibraryBrowser

/// A report whose every check found track `id`.
private func report(_ id: Int64) -> HealthReport {
    HealthReport(
        Dictionary(
            uniqueKeysWithValues: HealthCheck.allCases.map { ($0, HealthFindings(trackIDs: [id])) }
        ))
}

/// Waits up to 10 seconds for `condition`, then records what it saw.
@MainActor
private func waitFor(_ what: String, _ condition: () async throws -> Bool) async throws {
    let deadline = Date().addingTimeInterval(10)
    while try await !condition() {
        guard Date() < deadline else {
            Issue.record("timed out waiting for \(what)")
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}

@MainActor @Test func aRunThatFinishesAfterANewerOneIsDropped() async throws {
    var pending: [CheckedContinuation<HealthReport, any Error>] = []
    var shown: [HealthReport] = []
    let model = HealthModel(
        build: { try await withCheckedThrowingContinuation { pending.append($0) } },
        show: { shown.append($0) })
    var changes = 0
    model.changed = { changes += 1 }
    let first = Task { await model.run() }
    try await waitFor("the first build") { pending.count == 1 }
    let second = Task { await model.run() }
    try await waitFor("the second build") { pending.count == 2 }
    pending[1].resume(returning: report(2))
    await second.value
    #expect(!model.isRunning)
    pending[0].resume(returning: report(1))
    await first.value
    #expect(model.report == report(2))
    #expect(shown == [report(2)])
    #expect(changes == 1)
}

@MainActor @Test func aFailedRunIsReportedAndAnOvertakenFailureIsNot() async throws {
    struct Broken: Error {}
    var pending: [CheckedContinuation<HealthReport, any Error>] = []
    let model = HealthModel(
        build: { try await withCheckedThrowingContinuation { pending.append($0) } },
        show: { _ in })
    var failures: [String] = []
    model.failed = { failures.append($0) }
    let first = Task { await model.run() }
    try await waitFor("the first build") { pending.count == 1 }
    let second = Task { await model.run() }
    try await waitFor("the second build") { pending.count == 2 }
    pending[0].resume(throwing: Broken())
    await first.value
    #expect(failures.isEmpty)
    pending[1].resume(throwing: Broken())
    await second.value
    #expect(failures.count == 1)
    #expect(model.report == nil)
    #expect(!model.isRunning)
}

@MainActor @Test func aSavedCheckRunsTheReportAndListsItsTracks() async throws {
    let (root, databaseURL) = try browserLibrary.get()
    let index = try LibraryIndex(at: databaseURL)
    let expected = Set(
        try index.paths(ids: try index.healthReport()[.noAlbumArtist].trackIDs).values)
    try #require(!expected.isEmpty)
    let browser = LibraryBrowser(
        reader: try LibraryReader(databaseURL: databaseURL), index: index,
        layout: AppState().trackTable.defaultValue, browserHeight: 100,
        folders: [WatchedFolder(path: root, kind: .local)], groupByAlbumArtist: false)
    let sidebar = try #require(browser.sidebar as? SidebarController)
    _ = sidebar.view
    await browser.load(
        BrowserState(source: .health(.noAlbumArtist), genre: nil, artist: nil, album: nil))
    #expect(sidebar.selectedSource == .health(.noAlbumArtist))
    try await waitFor("the report's tracks") {
        browser.selectAllTracks()
        return Set(try await browser.selectedPaths()) == expected
    }
    #expect(browser.health.report != nil)
    let row = sidebar.outline.selectedRow
    let cell = sidebar.outlineView(
        sidebar.outline, viewFor: nil, item: try #require(sidebar.outline.item(atRow: row)))
    let texts = (cell?.subviews ?? []).compactMap { ($0 as? NSTextField)?.stringValue }
    #expect(texts == ["No Album Artist", number(expected.count)])
}
