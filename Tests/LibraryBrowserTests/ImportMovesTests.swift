import AppKit
import Foundation
import Settings
import Testing

@testable import Library
@testable import LibraryBrowser

/// Import Moves… says what it moved in a sheet on the window, keeps the lines that moved
/// nothing in the problems list, and has the change shared.
@MainActor @Test func importedMovesAreToldOnTheWindowWithTheirProblemsListed() async throws {
    let databaseURL = try writableBrowserDatabase()
    let browser = LibraryBrowser(
        reader: try LibraryReader(databaseURL: databaseURL),
        index: try LibraryIndex(at: databaseURL),
        layout: AppState().trackTable.defaultValue, browserHeight: 100, groupByAlbumArtist: false,
        thumbnails: nil)
    let window = NSWindow()
    var told: [(String, String, NSWindow)] = []
    browser.tell = { message, detail, over in told.append((message, detail, over)) }
    var edits = 0
    browser.edited = { edits += 1 }
    let problem = MoveListProblem(line: 3, reason: "the new file /M/a.flac isn't there")
    let list = URL(fileURLWithPath: "/lists/moves.txt", isDirectory: false)
    var imported: [URL] = []
    browser.importMoves(from: list, over: window) { url in
        imported.append(url)
        return MoveListImport(moved: 2, merged: 1, alreadyDone: 4, problems: [problem])
    }
    try await waitFor("the sheet") { !told.isEmpty }
    #expect(imported == [list])
    #expect(told.map(\.0) == ["Moved the stats of 3 tracks"])
    #expect(
        told.first?.1
            == "2 moved, 1 merged with stats the new path had, 4 already moved, 1 line with"
            + " problems, listed in the Problems window, where ⌘C copies them.")
    #expect(told.first?.2 === window)
    #expect(browser.status.importedMovesReport.map(\.line) == [problem.description])
    #expect(edits == 1)
}
