import AppKit
import Settings
import Testing

@testable import Library
@testable import LibraryBrowser

/// A browser over a writable copy of the shared library holding a manual playlist of three
/// tracks and a smart one, loaded with its sidebar in a window, the library selected.
@MainActor
private func browserWithPlaylists() async throws -> (
    LibraryBrowser, SidebarController, NSWindow, manual: Playlist, smart: Playlist
) {
    let databaseURL = try writableBrowserDatabase()
    let index = try LibraryIndex(at: databaseURL)
    let manual = try index.createPlaylist(named: "Mix")
    _ = try index.addToPlaylist(manual, trackIDs: Array(try index.trackIDs(sortedBy: .path)[0..<3]))
    let smart = try index.createPlaylist(
        named: "Smart",
        rules: SmartRules(match: .all, rules: [.init(.title, .contains, .text("a"))]))
    let browser = LibraryBrowser(
        reader: try LibraryReader(databaseURL: databaseURL), index: index,
        layout: AppState().trackTable.defaultValue, browserHeight: 100, groupByAlbumArtist: false)
    let sidebar = try #require(browser.sidebar as? SidebarController)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 400), styleMask: [.titled],
        backing: .buffered, defer: false)
    window.contentView = sidebar.view
    await browser.load(BrowserState(source: nil, genre: nil, artist: nil, album: nil))
    window.layoutIfNeeded()
    return (
        browser, sidebar, window, try index.playlist(manual), try index.playlist(smart)
    )
}

@MainActor
private func row(of playlist: Playlist, in sidebar: SidebarController) throws -> Int {
    let outline = sidebar.outline
    return try #require(
        (0..<outline.numberOfRows).first { row in
            outline.view(atColumn: 0, row: row, makeIfNecessary: true).flatMap {
                ($0 as? NSTableCellView)?.textField?.stringValue
            } == playlist.name
        })
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

@Test func aCopyIsNamedAsFinderNamesOneAndARenameMustChangeTheName() {
    #expect(PlaylistName.copy(of: "Mix", taken: ["Mix"]) == "Mix copy")
    #expect(PlaylistName.copy(of: "Mix", taken: ["Mix", "mix COPY", "Mix copy 2"]) == "Mix copy 3")
    #expect(PlaylistName.edited("  Road trip \n", from: "Mix") == "Road trip")
    #expect(PlaylistName.edited("   ", from: "Mix") == nil)
    #expect(PlaylistName.edited("Mix ", from: "Mix") == nil)
}

@MainActor @Test func theContextMenuActsOnTheRowClickedNotTheSelection() async throws {
    let (browser, sidebar, _, manual, smart) = try await browserWithPlaylists()
    var deleted: [Playlist] = []
    var edited: [Playlist] = []
    browser.confirmDeletePlaylist = { deleted.append($0) }
    browser.editRules = { edited.append($0) }
    #expect(sidebar.selectedSource == nil)
    let menu = NSMenu()

    sidebar.fill(menu, row: try row(of: smart, in: sidebar))
    #expect(
        menu.items.map(\.title) == ["Rename", "Duplicate", "Delete…", "", "Edit Smart Playlist…"])
    menu.performActionForItem(at: 4)
    #expect(edited == [smart])

    sidebar.fill(menu, row: try row(of: manual, in: sidebar))
    #expect(menu.items.map(\.title) == ["Rename", "Duplicate", "Delete…"])
    menu.performActionForItem(at: 2)
    #expect(deleted == [manual])

    // Neither row was selected for any of it, and the library's row has no menu.
    #expect(sidebar.selectedSource == nil)
    sidebar.fill(menu, row: 1)
    #expect(menu.items.isEmpty)

    sidebar.fill(menu, row: try row(of: manual, in: sidebar))
    menu.performActionForItem(at: 1)
    try await waitFor("the copy selected") {
        browser.shownPlaylist?.name == "Mix copy"
            && sidebar.selectedSource == browser.shownPlaylist.map { .playlist($0.id) }
    }
    #expect(browser.shownPlaylist?.isManual == true)
}

@MainActor @Test func aNameEditedInItsRowRenamesThePlaylistUnlessEscOrNothingChanged()
    async throws
{
    let (_, sidebar, window, manual, _) = try await browserWithPlaylists()
    var renamed: [String] = []
    sidebar.renamePlaylist = { id, name in
        #expect(id == manual.id)
        renamed.append(name)
    }
    let row = try row(of: manual, in: sidebar)
    func edit(_ text: String) throws -> NSTextView {
        sidebar.beginRename(row: row)
        #expect(sidebar.isRenaming)
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.string = text
        return editor
    }

    // Return ends the edit as the field does.
    try edit(" Road trip ").doCommand(by: #selector(NSResponder.insertNewline(_:)))
    #expect(!sidebar.isRenaming)
    #expect(renamed == ["Road trip"])

    try edit("Gone").doCommand(by: #selector(NSResponder.cancelOperation(_:)))
    #expect(!sidebar.isRenaming)
    _ = try edit("  ")
    window.makeFirstResponder(sidebar.outline)
    _ = try edit(manual.name)
    window.makeFirstResponder(sidebar.outline)
    #expect(renamed == ["Road trip"])

    // Return on a selected playlist starts the edit, rather than playing.
    sidebar.outline.selectRowIndexes([row], byExtendingSelection: false)
    window.makeFirstResponder(sidebar.outline)
    let event = try #require(
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    sidebar.outline.keyDown(with: event)
    #expect(sidebar.isRenaming)
}
