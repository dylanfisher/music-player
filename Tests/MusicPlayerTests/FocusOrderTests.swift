import AppKit
import Foundation
import KeyChord
import Testing

@testable import Commands
@testable import LibraryBrowser
@testable import MusicPlayer

@Test func focusStepsBackOverTheAreasItSteppedForwardOver() {
    for count in 1...6 {
        for start in [nil] + Array(0..<count) {
            var forward: [Int] = []
            var current = start
            for _ in 0..<count + 2 {
                current = focusArea(after: current, of: count, forward: true)
                forward.append(current!)
            }
            var backward: [Int] = []
            for _ in 0..<count + 1 {
                current = focusArea(after: current, of: count, forward: false)
                backward.append(current!)
            }
            #expect(backward == forward.dropLast().reversed())
        }
        #expect(focusArea(after: nil, of: count, forward: true) == 0)
        #expect(focusArea(after: nil, of: count, forward: false) == count - 1)
    }
    #expect(focusArea(after: nil, of: 0, forward: true) == nil)
}

/// The fixture's window, with Tab and ⇧Tab run through the registry as the app runs them.
@MainActor
private func focusFixture() async throws -> MainWindowFixture {
    let fixture = try await MainWindowFixture()
    let dispatcher = CommandDispatcher(
        bindings: try KeyBindings(
            AppCommands.all(), overrides: [:], rules: AppMenus.rules(appName: "App")))
    let window = fixture.window
    dispatcher.handle(.focusNextArea) { window.moveFocus(forward: true) }
    dispatcher.handle(.focusPreviousArea) { window.moveFocus(forward: false) }
    fixture.browser.keyCommand = { dispatcher.key($0) }
    fixture.window.queue.keyCommand = { dispatcher.key($0) }
    return fixture
}

@MainActor
private func press(_ chord: KeyChord, in window: NSWindow) throws {
    let characters = chord.modifiers.contains(.shift) ? "\u{19}" : "\t"
    let event = try #require(
        NSEvent.keyEvent(
            with: .keyDown, location: .zero,
            modifierFlags: chord.modifiers.contains(.shift) ? .shift : [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 48))
    try #require(window.firstResponder).keyDown(with: event)
}

@MainActor
@Test(arguments: [
    (sidebar: true, columns: true, queue: true), (sidebar: false, columns: true, queue: true),
    (sidebar: true, columns: false, queue: false), (sidebar: false, columns: false, queue: true),
])
func shiftTabVisitsTabsAreasInReverse(sidebar: Bool, columns: Bool, queue: Bool) async throws {
    let fixture = try await focusFixture()
    defer { fixture.close() }
    let window = fixture.window
    if window.isSidebarVisible != sidebar { window.toggleSidebar() }
    if fixture.browser.isBrowserVisible != columns { fixture.browser.toggleBrowser() }
    if window.isQueueVisible != queue { window.toggleQueue() }
    let areas = window.focusAreas
    let shown: [Int] = [sidebar ? 1 : 0, columns ? 3 : 0, 1, queue ? 1 : 0]
    #expect(areas.count == shown.reduce(0, +))
    window.window.makeFirstResponder(areas[0])
    func walk(_ chord: KeyChord) throws -> [Int?] {
        try areas.map { _ in
            try press(chord, in: window.window)
            return areas.firstIndex { $0 === window.window.firstResponder }
        }
    }
    let count = areas.count
    // From the first area: the next ones round to the first, then back the same way.
    let forward = try walk(KeyChord(.tab))
    #expect(forward == Array(1..<count) + [0])
    let backward = try walk(KeyChord(.tab, .shift))
    #expect(backward == Array((0..<count).reversed()))
}

@MainActor @Test func shiftTabFromTheSecondColumnFocusesTheFirstAtOnce() async throws {
    let fixture = try await focusFixture()
    defer { fixture.close() }
    let window = fixture.window
    if !window.isSidebarVisible { window.toggleSidebar() }
    if !fixture.browser.isBrowserVisible { fixture.browser.toggleBrowser() }
    let areas = window.focusAreas
    window.window.makeFirstResponder(areas[2])
    try press(KeyChord(.tab, .shift), in: window.window)
    #expect(window.window.firstResponder === areas[1])
}

@MainActor @Test func theSearchFieldsTabAndShiftTabEnterTheAreasAtEitherEnd() async throws {
    let fixture = try await focusFixture()
    defer { fixture.close() }
    let window = fixture.window
    let browser = fixture.browser
    let editor = NSTextView()
    // The search field's editor has the keys, which no area is.
    window.window.makeFirstResponder(nil)
    #expect(
        browser.control(
            browser.searchField, textView: editor,
            doCommandBy: #selector(NSResponder.insertTab(_:))))
    #expect(window.window.firstResponder === window.focusAreas.first)
    window.window.makeFirstResponder(nil)
    #expect(
        browser.control(
            browser.searchField, textView: editor,
            doCommandBy: #selector(NSResponder.insertBacktab(_:))))
    #expect(window.window.firstResponder === window.focusAreas.last)
}

@MainActor @Test func showingTheColumnsFocusesTheFirst() async throws {
    let fixture = try await focusFixture()
    defer { fixture.close() }
    let browser = fixture.browser
    if browser.isBrowserVisible { browser.toggleBrowser() }
    browser.focusTracks()
    browser.toggleBrowser()
    #expect(fixture.window.window.firstResponder === browser.focusAreas[1])
}

/// The playing track, selected in All, isn't in the genre chosen next, so the table reloads
/// with nothing selected; Tab into it selects its first row, so the keys are seen to arrive.
@MainActor @Test func tabIntoATableLeftWithNoSelectionSelectsItsFirstRow() async throws {
    let fixture = try await focusFixture()
    defer { fixture.close() }
    let window = fixture.window
    let browser = fixture.browser
    if !window.isSidebarVisible { window.toggleSidebar() }
    if !browser.isBrowserVisible { browser.toggleBrowser() }
    let tracks = browser.table.table
    tracks.selectRowIndexes([0], byExtendingSelection: false)
    let selected = try await browser.selectedPaths()
    let playing = try #require(selected.first)
    browser.showPlaying(path: playing)
    let model = browser.model
    let albums = model.columns.count - 1
    var emptied = false
    for entry in model.entries[albums] {
        await model.select(model.columns[albums], entry.value)
        if tracks.selectedRowIndexes.isEmpty, tracks.numberOfRows > 0 {
            emptied = true
            break
        }
    }
    try #require(emptied)
    // The album column, the last before the track table.
    window.window.makeFirstResponder(window.focusAreas[3])
    try press(KeyChord(.tab), in: window.window)
    #expect(window.window.firstResponder === tracks)
    #expect(tracks.selectedRowIndexes == [0])
}
