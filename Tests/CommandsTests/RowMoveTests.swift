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
