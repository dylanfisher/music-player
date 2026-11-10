import AppKit
import Testing

@testable import Discogs
@testable import DiscogsTagger
@testable import Fixtures

// The album list keeps its place: the album selected stays selected and in view through Other
// Releases… and the choice made there, whichever tab the choice moves it to (phase 74).

private let titles = ["Östermalm", "Gamla Stan", "Kungsholmen"]

/// Sixty Exact albums, more than the list shows at once; one chosen release makes an album
/// Likely.
@MainActor
private func manyAlbums() async -> TaggerModel {
    let albums = (1...60).map { album(Int64($0), String(format: "Album %02d", $0), titles: titles) }
    let tagger = await model(
        Seen(), albums: albums,
        matches: { album, chosen in
            match(
                album, release(chosen ?? Int(album.id) * 10, album.title, titles: titles),
                tier: chosen == nil ? .exact : .likely, candidates: [Int(album.id) * 10 + 1])
        })
    tagger.analyze()
    await tagger.finished()
    return tagger
}

/// The tagger's window on `tagger`, in front, at a height that shows a few albums.
@MainActor
private func shown(_ tagger: TaggerModel) throws -> (TaggerWindow, NSWindow) {
    let controller = TaggerWindow(model: tagger)
    let window = try #require(controller.window)
    window.setContentSize(NSSize(width: 1000, height: 480))
    window.contentView?.layoutSubtreeIfNeeded()
    window.orderFront(nil)
    return (controller, window)
}

/// Whether the album list's row `row` is selected alone and in view.
@MainActor
private func isSelectedInView(_ controller: TaggerWindow, _ row: Int) -> Bool {
    let table = controller.albumTable
    return table.selectedRowIndexes == [row]
        && table.visibleRect.contains(table.rect(ofRow: row))
}

/// Selects `id`'s row in the list as a click does, and scrolls to it.
@MainActor
private func select(_ id: Int64, in controller: TaggerWindow) throws {
    let row = try #require(controller.shownAlbums.firstIndex { $0.id == id })
    controller.albumTable.selectRowIndexes([row], byExtendingSelection: false)
    controller.albumTable.scrollRowToVisible(row)
}

/// Other Releases… opened and closed with nothing chosen leaves the album selected, in view.
@MainActor
@Test func otherReleasesClosedLeavesTheAlbumSelected() async throws {
    let tagger = await manyAlbums()
    let (controller, window) = try shown(tagger)
    defer { window.close() }
    try select(45, in: controller)
    #expect(isSelectedInView(controller, 44))

    click(controller.otherReleasesButton)
    try await eventually { window.attachedSheet?.windowController is ReleasesSheet }
    let sheet = try #require(window.attachedSheet?.windowController as? ReleasesSheet)
    #expect(isSelectedInView(controller, 44), "while the sheet shows")
    sheet.endSheet()
    try await eventually { window.attachedSheet == nil }
    #expect(tagger.selectedID == 45)
    #expect(isSelectedInView(controller, 44))
}

/// A release chosen in Other Releases… that moves the album to Likely shows Likely with the
/// album selected and scrolled to; the tab it left still has an album selected.
@MainActor
@Test func aReleaseChosenThatMovesTheAlbumKeepsItSelected() async throws {
    let tagger = await manyAlbums()
    let (controller, window) = try shown(tagger)
    defer { window.close() }
    try select(45, in: controller)

    click(controller.otherReleasesButton)
    try await eventually { window.attachedSheet?.windowController is ReleasesSheet }
    let sheet = try #require(window.attachedSheet?.windowController as? ReleasesSheet)
    let row = try #require(sheet.shown.firstIndex { $0.summary.id == 451 })
    sheet.table.selectRowIndexes([row], byExtendingSelection: false)
    sheet.table.sendAction(sheet.table.doubleAction, to: sheet.table.target)
    try await eventually { tagger.selected?.match.releaseID == 451 && tagger.rematchingID == nil }
    #expect(tagger.tab == .likely)
    #expect(tagger.selectedID == 45)
    #expect(controller.shownAlbums.map(\.id) == [45])
    #expect(isSelectedInView(controller, 0))

    controller.tabs.selectedSegment = TaggerTab.allCases.firstIndex(of: .exact)!
    controller.tabs.sendAction(controller.tabs.action, to: controller.tabs.target)
    #expect(controller.albumTable.selectedRowIndexes.count == 1, "Exact has one selected")
}

/// A release chosen that keeps the album in its tab leaves it selected and in view, though
/// the list was scrolled away from it while the release was matched.
@MainActor
@Test func aReleaseChosenInTheSameTabKeepsTheAlbumSelected() async throws {
    let albums = (1...60).map { album(Int64($0), String(format: "Album %02d", $0), titles: titles) }
    let tagger = await model(
        Seen(), albums: albums,
        matches: { album, chosen in
            match(
                album, release(chosen ?? Int(album.id) * 10, album.title, titles: titles),
                tier: .exact, candidates: [Int(album.id) * 10 + 1])
        })
    tagger.analyze()
    await tagger.finished()
    let (controller, window) = try shown(tagger)
    defer { window.close() }
    try select(45, in: controller)
    click(controller.otherReleasesButton)
    try await eventually { window.attachedSheet?.windowController is ReleasesSheet }
    let sheet = try #require(window.attachedSheet?.windowController as? ReleasesSheet)
    let row = try #require(sheet.shown.firstIndex { $0.summary.id == 451 })
    sheet.table.selectRowIndexes([row], byExtendingSelection: false)
    sheet.table.sendAction(sheet.table.doubleAction, to: sheet.table.target)
    try await eventually { tagger.selected?.match.releaseID == 451 && tagger.rematchingID == nil }
    #expect(tagger.tab == .exact)
    #expect(isSelectedInView(controller, 44))
}

/// An album selected in another tab than the one shown, as after an Analyze that moved it,
/// leaves the list with its first album selected rather than none.
@MainActor
@Test func theListNeverShowsNothingSelectedWhileItHasAlbums() async throws {
    let tagger = await manyAlbums()
    let (controller, window) = try shown(tagger)
    defer { window.close() }
    await tagger.choose(451, for: 45)
    #expect(tagger.selectedID == 1, "the user was on the first album")
    #expect(tagger.tab == .exact)
    tagger.selectedID = 45
    controller.refresh()
    #expect(!controller.albumTable.selectedRowIndexes.isEmpty)
    #expect(tagger.albums(in: tagger.tab).map(\.id).contains(tagger.selectedID ?? -1))
    #expect(!controller.albumTable.allowsEmptySelection, "a click below the rows keeps one")
}
