import Fixtures
import Foundation
import Settings
import Testing

@testable import Library

/// The first columns of the owner's Swinsian table on 2026-11-02.
private let ownersColumns: [(id: String, width: Double)] = [
    ("artwork", 163), ("currentlyPlaying", 64), ("title", 397), ("trackNumbers", 66),
    ("length", 59), ("artist", 362), ("fileSize", 76),
]

private func read(_ columns: [(id: String, width: Double)], sort: (String, Bool)?) throws
    -> SwinsianColumns
{
    try SwinsianColumns(
        preferences: try swinsianPreferences(columns: columns, sort: sort),
        source: "/prefs.plist")
}

@Test func swinsiansColumnsMapInOrderAndTheRestAreListed() throws {
    let columns = try read(ownersColumns, sort: ("artist", false))
    #expect(
        columns.columns == [
            ColumnLayout(column: .art, width: 163), ColumnLayout(column: .title, width: 397),
            ColumnLayout(column: .trackOfTotal, width: 66),
            ColumnLayout(column: .duration, width: 59), ColumnLayout(column: .artist, width: 362),
            ColumnLayout(column: .size, width: 76),
        ])
    #expect(columns.sortColumn == .artist && !columns.sortAscending)
    #expect(columns.skipped == ["currentlyPlaying: no such column here"])
    let layout = columns.layout(over: AppState().trackTable.defaultValue)
    #expect(layout.columns == columns.columns && layout.sortColumn == .artist)
    #expect(!layout.sortAscending && layout.problem() == nil)
}

@Test func aSortThatDoesntMapKeepsTheTablesSort() throws {
    let current = TrackTableLayout(
        columns: [ColumnLayout(column: .title, width: 100)], sortColumn: .year,
        sortAscending: false)
    let unmapped = "sort by currentlyPlaying: no such column here, so the table's sort stays"
    let cases: [((String, Bool)?, String)] = [
        (("currentlyPlaying", true), unmapped),
        (nil, "sort: Swinsian keeps none, so the table's sort stays"),
    ]
    for (sort, reason) in cases {
        let columns = try read([("title", 300)], sort: sort)
        #expect(columns.skipped == [reason])
        let layout = columns.layout(over: current)
        #expect(layout.sortColumn == .year && !layout.sortAscending)
        #expect(layout.columns == [ColumnLayout(column: .title, width: 300)])
    }
}

@Test func badColumnsAreSkippedAndSaySo() throws {
    let columns = try read(
        [("title", 300), ("title", 200), ("album", 5000), ("year", 5)], sort: ("title", true))
    #expect(columns.columns == [ColumnLayout(column: .title, width: 300)])
    #expect(
        columns.skipped == [
            "title: listed twice", "album: its width 5000.0 is outside 20.0...2000.0",
            "year: its width 5.0 is outside 20.0...2000.0",
        ])
}

/// The fixture writes the reader's keys, so they're checked here against the owner's file.
@Test func theKeysAreTheOnesSwinsianWrites() {
    #expect(SwinsianColumns.columnsKey == "MainTableColumns-Ver1")
    #expect(SwinsianColumns.columnIDKey == "TableColumnIdentifier")
    #expect(SwinsianColumns.columnWidthKey == "TableColumnWidth")
    #expect(SwinsianColumns.sortKey == "NSTableView Sort Ordering v2 main_track_table")
    #expect(SwinsianColumns.sortIDKey == "Identifier")
    #expect(SwinsianColumns.sortAscendingKey == "Ascending")
}

@Test func preferencesWithoutAColumnWeHaveAreRefused() throws {
    #expect(throws: PlayerImportError.noColumns) {
        try read([("currentlyPlaying", 64)], sort: nil)
    }
    let other = try PropertyListSerialization.data(
        fromPropertyList: ["GridSortKey": "album"], format: .binary, options: 0)
    #expect(throws: PlayerImportError.notPreferences("it has no MainTableColumns-Ver1 list")) {
        try SwinsianColumns(preferences: other, source: "/prefs.plist")
    }
}

@Test func aSortArchiveThatDoesntReadKeepsTheTablesSort() throws {
    let preferences = try PropertyListSerialization.data(
        fromPropertyList: [
            SwinsianColumns.columnsKey: [
                [SwinsianColumns.columnIDKey: "title", SwinsianColumns.columnWidthKey: 300]
            ],
            SwinsianColumns.sortKey: Data("not an archive".utf8),
        ], format: .binary, options: 0)
    let columns = try SwinsianColumns(preferences: preferences, source: "/prefs.plist")
    #expect(columns.sortColumn == nil)
    #expect(columns.skipped == ["sort: couldn't be read, so the table's sort stays"])
}

@Test func theFileIsReadOnlyWhenItsARegularFile() throws {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("swinsian-columns-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("prefs.plist", isDirectory: false)
    try swinsianPreferences(columns: ownersColumns, sort: nil).write(to: file)
    let columns = try SwinsianColumns(preferencesAt: file)
    #expect(columns.columns.count == 6 && columns.source == file.path)
    let link = folder.appendingPathComponent("link.plist", isDirectory: false)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    #expect(throws: PlayerImportError.self) { try SwinsianColumns(preferencesAt: link) }
}
