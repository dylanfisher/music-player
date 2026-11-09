import Foundation
import KeyChord
import Testing

@testable import Commands

private func at(_ row: Int) -> ListSelection {
    ListSelection(rows: [row], cursor: row, anchor: row)
}

@Test func plainMovesSelectTheTargetAlone() {
    let many = ListSelection(rows: [2, 3, 4], cursor: 4, anchor: 2)
    #expect(many.moved(.down, extending: false, rowCount: 10, pageRows: 3) == at(5))
    #expect(at(5).moved(.tenDown, extending: false, rowCount: 10, pageRows: 3) == at(9))
    #expect(at(5).moved(.tenUp, extending: false, rowCount: 10, pageRows: 3) == at(0))
    #expect(at(5).moved(.pageDown, extending: false, rowCount: 10, pageRows: 3) == at(8))
    #expect(at(5).moved(.first, extending: false, rowCount: 10, pageRows: 3) == at(0))
    #expect(at(5).moved(.last, extending: false, rowCount: 10, pageRows: 3) == at(9))
}

@Test func withNoCursorDownStartsAtTheTopAndUpAtTheBottom() {
    let none = ListSelection(rows: [], cursor: nil, anchor: nil)
    #expect(none.moved(.down, extending: false, rowCount: 10, pageRows: 3) == at(0))
    #expect(none.moved(.up, extending: false, rowCount: 10, pageRows: 3) == at(9))
    #expect(none.moved(.down, extending: false, rowCount: 0, pageRows: 3) == none)
}

@Test func extendingKeepsTheAnchorAndRowsOutsideTheRange() {
    // Row 8 was Cmd-clicked; the range runs from the anchor, 3.
    let start = ListSelection(rows: [3, 4, 8], cursor: 4, anchor: 3)
    let down = start.moved(.down, extending: true, rowCount: 10, pageRows: 3)
    #expect(down == ListSelection(rows: [3, 4, 5, 8], cursor: 5, anchor: 3))
    let back = down.moved(.up, extending: true, rowCount: 10, pageRows: 3)
        .moved(.up, extending: true, rowCount: 10, pageRows: 3)
        .moved(.up, extending: true, rowCount: 10, pageRows: 3)
    #expect(back == ListSelection(rows: [2, 3, 8], cursor: 2, anchor: 3))
}

@MainActor @Test func keysRunTheirCommandsOrSayWhyNot() throws {
    let dispatcher = CommandDispatcher(
        bindings: try KeyBindings(AppCommands.all(), overrides: [:], rules: ChordRules()))
    var ran: [CommandID] = []
    var on = true
    dispatcher.handle(.playPause, enabled: { on }, run: { ran.append(.playPause) })
    #expect(dispatcher.key([.init(.space)]) == .ran)
    on = false
    #expect(dispatcher.key([.init(.space)]) == .refused)
    #expect(dispatcher.key([.init("j", .command)]) == .unbound)
    // A command with no handler is off.
    #expect(dispatcher.key([.init("k", .command)]) == .refused)
    #expect(ran == [.playPause])
}

@MainActor @Test func shiftWithOptionArrowsExtendOverTheRowsTheyJump() throws {
    let bindings = try KeyBindings(AppCommands.all(), overrides: [:], rules: ChordRules())
    let down = try #require(bindings.registry.command(for: KeyChord(.down, [.option, .shift])))
    let up = try #require(bindings.registry.command(for: KeyChord(.up, [.option, .shift])))
    let jumpDown = try #require(RowMove.commands[down])
    let jumpUp = try #require(RowMove.commands[up])
    let jumped = at(2).moved(
        jumpDown.move, extending: jumpDown.extending, rowCount: 20, pageRows: 3)
    #expect(jumped == ListSelection(rows: IndexSet(2...12), cursor: 12, anchor: 2))
    let back = jumped.moved(jumpUp.move, extending: jumpUp.extending, rowCount: 20, pageRows: 3)
    #expect(back == ListSelection(rows: [2], cursor: 2, anchor: 2))
}

/// Rows 0–2 album 1, rows 3–4 no album, rows 5–7 album 2.
private func albums(_ row: Int) -> Int64? { row < 3 ? 1 : row < 5 ? nil : 2 }

private func album(_ selection: ListSelection, _ move: RowMove, extending: Bool = false)
    -> ListSelection
{
    selection.moved(move, extending: extending, rowCount: 8, pageRows: 3, album: albums)
}

@Test func albumMovesGoToTheFirstTrackOfTheNextOrPreviousAlbum() {
    #expect(album(at(1), .nextAlbum) == at(3))
    #expect(album(at(3), .nextAlbum) == at(5))
    // Past the last album there's no next one to go to.
    #expect(album(at(6), .nextAlbum) == at(6))
    // From inside an album, the album before it, not its own start.
    #expect(album(at(6), .previousAlbum) == at(3))
    #expect(album(at(4), .previousAlbum) == at(0))
    // The first album has none before it: its first row.
    #expect(album(at(2), .previousAlbum) == at(0))
    let none = ListSelection(rows: [], cursor: nil, anchor: nil)
    #expect(album(none, .nextAlbum) == at(0))
    #expect(album(none, .previousAlbum) == at(5))
}

@Test func albumMovesExtendWithShiftAndDoNothingWithoutAlbums() {
    #expect(
        album(at(1), .nextAlbum, extending: true)
            == ListSelection(rows: [1, 2, 3], cursor: 3, anchor: 1))
    #expect(at(4).moved(.nextAlbum, extending: false, rowCount: 8, pageRows: 3) == at(4))
}

@MainActor @Test func controlArrowsMoveByAlbum() throws {
    let registry = try KeyBindings(AppCommands.all(), overrides: [:], rules: ChordRules())
        .registry
    #expect(registry.command(for: KeyChord(.down, .control)) == .nextAlbum)
    #expect(registry.command(for: KeyChord(.up, .control)) == .previousAlbum)
    #expect(registry.command(for: KeyChord(.down, [.control, .shift])) == .extendToNextAlbum)
    #expect(registry.command(for: KeyChord(.up, [.control, .shift])) == .extendToPreviousAlbum)
}
