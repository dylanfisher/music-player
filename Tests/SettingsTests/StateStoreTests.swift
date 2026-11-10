import Foundation
import Testing

@testable import Settings

private enum Theme: String, SettingChoice {
    case light, dark

    var title: String { rawValue.capitalized }
}

/// One setting of each kind, so the store is tested apart from the app's real settings.
private struct TestSchema: SettingsSchema {
    let flag = Setting("flag", title: "Flag", default: false, "A bool.")
    let count = Setting(
        "count", title: "Count", default: 5, range: 1...10, "An integer with a range.")
    let gain = Setting("gain", title: "Gain", default: 0.5, range: 0...1, "A number with a range.")
    let name = Setting("name", title: "Name", default: "", "A string.")
    let theme = Setting("theme", title: "Theme", default: Theme.light, "A choice.")
    let device = Setting<String?>("device", title: "Device", default: "built-in", "An optional.")
    let tags = Setting<[String]>("tags", title: "Tags", default: [], "A list.")
    let folders = Setting<[WatchedFolder]>(
        "folders", title: "Folders", default: [], "A structured list.")
    let limit = Setting<Int?>(
        "limit", title: "Limit", default: nil, range: 1...4, "An optional with a range.")
}

/// A settings file in a fresh temporary directory that nothing else touches.
private func temporaryFile() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("settings-\(UUID().uuidString)/settings.json")
}

private func store(_ json: String? = nil) throws -> StateStore<TestSchema> {
    let url = temporaryFile()
    if let json {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
    }
    return try StateStore(TestSchema(), fileURL: url)
}

private func fileContents(_ store: StateStore<TestSchema>) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as! [String: Any]
}

/// The settings of `schema` by key, as `parse` takes them.
func keyed(_ schema: some SettingsSchema) -> [String: SettingDescriptor] {
    Dictionary(uniqueKeysWithValues: schema.settings.map { ($0.key, $0) })
}

/// The problems a file's values are dropped for.
private func problems(_ json: String) -> [SettingProblem] {
    do {
        let dropped = try parse(Data(json.utf8), path: "test.json", settings: keyed(TestSchema()))
            .dropped
        guard case .invalid(_, let problems)? = dropped else {
            Issue.record("the file was accepted")
            return []
        }
        return problems
    } catch {
        Issue.record("expected the file to parse, got \(error)")
        return []
    }
}

@Test func missingFileMeansDefaults() throws {
    let settings = try store()
    #expect(settings[\.flag] == false)
    #expect(settings[\.count] == 5)
    #expect(settings[\.theme] == .light)
    #expect(settings[\.device] == "built-in")
    #expect(!FileManager.default.fileExists(atPath: settings.fileURL.path))
}

@Test func savesOnlyChangedValues() throws {
    let settings = try store()
    try settings.set(\.count, to: 7)
    try settings.set(\.flag, to: false)
    #expect(try fileContents(settings).keys.sorted() == ["count"])

    try settings.set(\.count, to: 5)
    #expect(try fileContents(settings).isEmpty)
}

@Test func aValueEqualToTheOneInEffectWritesNothing() throws {
    let settings = try store()
    try settings.set(\.flag, to: false)
    #expect(!FileManager.default.fileExists(atPath: settings.fileURL.path))
    try settings.set(\.count, to: 7)
    let written = try FileManager.default.attributesOfItem(atPath: settings.fileURL.path)
    try settings.set(\.count, to: 7)
    try settings.set(\.flag, to: false)
    let after = try FileManager.default.attributesOfItem(atPath: settings.fileURL.path)
    // An atomic write replaces the file, so a write gives it a new file number.
    #expect(after[.systemFileNumber] as? Int == written[.systemFileNumber] as? Int)
}

@Test func valuesSurviveAReload() throws {
    let settings = try store()
    let folder = WatchedFolder(
        path: "/Volumes/Music", kind: .network, exclude: ["*.cue"], pollIntervalMinutes: 30)
    try settings.set(\.flag, to: true)
    try settings.set(\.gain, to: 0.25)
    try settings.set(\.name, to: "Den")
    try settings.set(\.theme, to: .dark)
    try settings.set(\.device, to: nil)
    try settings.set(\.tags, to: ["a", "b"])
    try settings.set(\.folders, to: [folder])

    let reloaded = try StateStore(TestSchema(), fileURL: settings.fileURL)
    #expect(reloaded[\.flag] == true)
    #expect(reloaded[\.gain] == 0.25)
    #expect(reloaded[\.name] == "Den")
    #expect(reloaded[\.theme] == .dark)
    #expect(reloaded[\.device] == nil)
    #expect(reloaded[\.tags] == ["a", "b"])
    #expect(reloaded[\.folders] == [folder])
}

@Test func rejectsUnknownKeys() {
    #expect(problems(#"{"colour": "red"}"#) == [SettingProblem(key: "colour", reason: .unknownKey)])
}

@Test func rejectsWrongTypes() {
    #expect(
        problems(#"{"flag": 1, "count": 2.5, "name": null, "theme": "blue"}"#) == [
            SettingProblem(key: "count", reason: .wrongType(expected: Int.typeName, detail: nil)),
            SettingProblem(key: "flag", reason: .wrongType(expected: Bool.typeName, detail: nil)),
            SettingProblem(key: "name", reason: .wrongType(expected: String.typeName, detail: nil)),
            SettingProblem(
                key: "theme",
                reason: .wrongType(expected: #"one of "light", "dark""#, detail: nil)),
        ])
}

@Test func rejectsValuesOutOfRange() {
    #expect(
        problems(#"{"count": 11, "gain": -0.5, "limit": 5}"#) == [
            SettingProblem(key: "count", reason: .outOfRange("11 is outside 1...10")),
            SettingProblem(key: "gain", reason: .outOfRange("-0.5 is outside 0.0...1.0")),
            SettingProblem(key: "limit", reason: .outOfRange("5 is outside 1...4")),
        ])
}

@Test func acceptsAnOptionalInsideItsRangeOrNull() throws {
    let limits = try parse(
        Data(#"{"limit": 4}"#.utf8), path: "test.json", settings: keyed(TestSchema()))
    #expect(limits.values["limit"] as? Int == 4)
    let none = try parse(
        Data(#"{"limit": null}"#.utf8), path: "test.json", settings: keyed(TestSchema()))
    #expect(none.values.keys.contains("limit"))
}

@Test func namesTheBadFieldInsideAStructuredValue() throws {
    let missing = problems(#"{"folders": [{"path": "/Music", "kind": "local"}]}"#)
    #expect(missing.map(\.key) == ["folders"])
    #expect("\(missing[0].reason)".contains("[0].include: missing"))

    let badKind = problems(
        #"{"folders": [{"path": "/M", "kind": "smb", "include": [], "exclude": [],"#
            + #" "pollIntervalMinutes": 15}]}"#)
    #expect("\(badKind[0].reason)".contains("[0].kind"))

    let unknown = problems(
        #"{"folders": [{"path": "/M", "kind": "local", "include": [], "exclude": [],"#
            + #" "pollIntervalMinutes": 15, "bogus": 1}]}"#)
    #expect("\(unknown[0].reason)".contains("[0].bogus: unknown key"))

    #expect(
        problems(
            #"{"folders": [{"path": "Music", "kind": "local", "include": [], "exclude": [],"#
                + #" "pollIntervalMinutes": 0}]}"#)
            == [
                SettingProblem(
                    key: "folders", reason: .invalid(#"item 0: path "Music" isn't absolute"#))
            ])
}

@Test func errorMessageNamesTheFileAndKey() throws {
    let dropped = try parse(
        Data(#"{"count": 0}"#.utf8), path: "/x/state.json", settings: keyed(TestSchema())
    ).dropped
    #expect(dropped.map { "\($0)" } == "/x/state.json: \"count\": 0 is outside 1...10")
}

@Test func rejectsFilesThatArentAnObject() {
    for json in ["[1, 2]", "{"] {
        #expect(throws: SettingsError.self) {
            try parse(Data(json.utf8), path: "test.json", settings: keyed(TestSchema()))
        }
    }
}

@Test func setValidatesAndLeavesTheFileAlone() throws {
    let settings = try store()
    try settings.set(\.count, to: 3)
    #expect(throws: SettingsError.self) { try settings.set(\.count, to: 0) }
    #expect(settings[\.count] == 3)
    #expect(try fileContents(settings)["count"] as? Int == 3)
}

@Test func schemaListsSettingsInDeclarationOrder() {
    let settings = TestSchema().settings
    #expect(
        settings.map(\.key) == [
            "flag", "count", "gain", "name", "theme", "device", "tags", "folders", "limit",
        ])
    #expect(settings[1].kind == .integer(1...10))
    #expect(
        settings[4].kind
            == .choice([
                SettingKind.Choice(rawValue: "light", title: "Light"),
                SettingKind.Choice(rawValue: "dark", title: "Dark"),
            ]))
    #expect(settings[5].kind == .optional(.string))
    #expect(settings[7].kind == .list(.watchedFolder))
    #expect(settings[8].kind == .optional(.integer(1...4)))
}

@Test func appSettingsHaveUniqueKeysAndLoad() throws {
    let keys = AppSettings().settings.map(\.key)
    #expect(Set(keys).count == keys.count)
    let settings = try StateStore(AppSettings(), fileURL: temporaryFile())
    #expect(settings[\.hogMode] == false)
    #expect(settings[\.outputDeviceUID] == nil)
    #expect(settings[\.digitalVolume] == false)
}

@Test func digitalVolumeIsOffAndSaysItCostsBitPerfectOutput() {
    let setting = AppSettings().digitalVolume
    #expect(setting.defaultValue == false)
    #expect(setting.summary.contains("ends bit-perfect output"))
}

@Test func theReceiverSettingsSayWhichReceiversTheyWorkWith() {
    let schema = AppSettings()
    // The address reaches any receiver on Denon's protocol; only the search is Denon's alone.
    #expect(!schema.receiverEnabled.summary.contains("the Denon receiver"))
    #expect(schema.receiverEnabled.summary.contains("Marantz"))
    #expect(schema.receiverAddress.summary.contains("Marantz"))
}

@Test func theTrackTableAppearanceDefaultsToTheTableAsItWas() throws {
    let settings = try StateStore(AppSettings(), fileURL: temporaryFile())
    #expect(settings[\.columnLines] == false)
    #expect(settings[\.rowLines] == false)
    #expect(settings[\.albumLines] == false)
    #expect(settings[\.alternatingRows] == true)
    #expect(settings[\.rowHeight] == .regular)
    #expect(settings[\.artSize] == .fit)
    #expect(settings[\.statusBarLayout] == .defaultStatusBar)
    #expect(settings[\.statusBarStyle] == .minimal)
    let keys = AppSettings().settings.map(\.key).filter { $0.hasPrefix("appearance.") }
    #expect(
        keys == [
            "appearance.columnLines", "appearance.rowLines", "appearance.albumLines",
            "appearance.rowLineColor", "appearance.albumLineColor", "appearance.playingRowColor",
            "appearance.alternatingRows",
            "appearance.rowHeight", "appearance.artSize", "appearance.glass",
            "appearance.windowTitle",
            "appearance.headerStatusLayout", "appearance.customStatus1Layout",
            "appearance.customStatus2Layout", "appearance.customStatus3Layout",
            "appearance.headerTitleFormat",
            "appearance.statusBarStyle",
            "appearance.statusBarLayout", "appearance.downloadsStatusStyle",
        ])
}

/// The other windows' frames are an object by window name in the state file (ADR 0158).
@Test func eachWindowsFrameSurvivesAReload() throws {
    let url = temporaryFile()
    let settings = try StateStore(AppState(), fileURL: url)
    #expect(settings[\.windowFrames] == WindowFrames())
    let frames = WindowFrames([
        "Settings": WindowFrame(x: 1600, y: 300, width: 640, height: 500),
        "Downloads": WindowFrame(x: 1700, y: 100, width: 1100, height: 480),
    ])
    try settings.set(\.windowFrames, to: frames)
    #expect(try StateStore(AppState(), fileURL: url)[\.windowFrames] == frames)
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    let saved = (json?["window.frames"] as? [String: Any])?["Settings"] as? [String: Double]
    #expect(saved == ["x": 1600, "y": 300, "width": 640, "height": 500])
    let rect = CGRect(x: 1600, y: 300, width: 640, height: 500)
    #expect(WindowFrame(rect) == frames.frames["Settings"] && WindowFrame(rect).rect == rect)
    #expect(throws: SettingsError.self) {
        try settings.set(
            \.windowFrames,
            to: WindowFrames(["Tagger": WindowFrame(x: 0, y: 0, width: 0, height: 5)]))
    }
}

@Test func windowLayoutSurvivesAReloadAndRejectsBadValues() throws {
    let url = temporaryFile()
    let settings = try StateStore(AppState(), fileURL: url)
    let layout = TrackTableLayout(
        columns: [
            ColumnLayout(column: .path, width: 300), ColumnLayout(column: .title, width: 90),
        ],
        sortColumn: .dateAdded, sortAscending: false)
    try settings.set(\.trackTable, to: layout)
    try settings.set(\.windowFrame, to: WindowFrame(x: 10, y: 20, width: 800, height: 500))
    let reloaded = try StateStore(AppState(), fileURL: url)
    #expect(reloaded[\.trackTable] == layout)
    #expect(reloaded[\.windowFrame] == WindowFrame(x: 10, y: 20, width: 800, height: 500))

    let twice = TrackTableLayout(
        columns: [
            ColumnLayout(column: .title, width: 90), ColumnLayout(column: .title, width: 90),
        ],
        sortColumn: .title, sortAscending: true)
    #expect(throws: SettingsError.self) { try settings.set(\.trackTable, to: twice) }
    let empty = TrackTableLayout(columns: [], sortColumn: .title, sortAscending: true)
    #expect(throws: SettingsError.self) { try settings.set(\.trackTable, to: empty) }
    #expect(throws: SettingsError.self) {
        try settings.set(\.windowFrame, to: WindowFrame(x: 0, y: 0, width: 0, height: 5))
    }
    let wide = TrackTableLayout(
        columns: [ColumnLayout(column: .title, width: TrackTableLayout.widthRange.upperBound + 1)],
        sortColumn: .title, sortAscending: true)
    #expect(wide.problem()?.contains("width") == true)
    #expect(twice.problem() == "columns[1]: title is listed twice")
    let byRowNumber = TrackTableLayout(
        columns: [ColumnLayout(column: .rowNumber, width: 40)], sortColumn: .rowNumber,
        sortAscending: true)
    #expect(byRowNumber.problem() == "sortColumn: rowNumber can't be sorted by")
}

@Test func timelineColumnsAreNullUntilSavedAndRefuseWhatAPlayHasNot() throws {
    let url = temporaryFile()
    let settings = try StateStore(AppState(), fileURL: url)
    #expect(settings[\.timelineTable] == nil)
    let layout = TimelineLayout(
        playedWidth: 150,
        columns: [
            ColumnLayout(column: .artist, width: 120), ColumnLayout(column: .rating, width: 50),
        ]
    )
    try settings.set(\.timelineTable, to: layout)
    #expect(try StateStore(AppState(), fileURL: url)[\.timelineTable] == layout)
    // Played alone is a layout.
    #expect(TimelineLayout(playedWidth: 150, columns: []).problem() == nil)
    for column in [TrackColumn.art, .playlistOrder, .nowPlaying] {
        let shown = TimelineLayout(
            playedWidth: 150, columns: [ColumnLayout(column: column, width: 40)])
        #expect(
            shown.problem() == "columns[0]: the timeline can't show \(column.rawValue)")
        #expect(throws: SettingsError.self) { try settings.set(\.timelineTable, to: shown) }
    }
    let twice = TimelineLayout(
        playedWidth: 150,
        columns: [ColumnLayout(column: .title, width: 90), ColumnLayout(column: .title, width: 90)])
    #expect(twice.problem() == "columns[1]: title is listed twice")
    let narrow = TimelineLayout(playedWidth: 1, columns: [])
    #expect(narrow.problem()?.hasPrefix("playedWidth: width 1.0 is outside") == true)
}

@Test func toolbarItemsRepeatOnlyTheSpaces() throws {
    let settings = try StateStore(AppState(), fileURL: temporaryFile())
    let spaced: [ToolbarItem] = [.space, .search, .space, .flexibleSpace, .flexibleSpace]
    try settings.set(\.toolbarItems, to: spaced)
    #expect(settings[\.toolbarItems] == spaced)
    #expect(throws: SettingsError.self) {
        try settings.set(\.toolbarItems, to: [.transport, .search, .transport])
    }
}

@Test func windowLayoutRejectsUnknownKeysAtEveryLevel() throws {
    func reason(_ json: String) throws -> String {
        let url = temporaryFile()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
        let parsed = try parse(Data(contentsOf: url), path: url.path, settings: keyed(AppState()))
        guard case .invalid(_, let problems)? = parsed.dropped else {
            Issue.record("accepted \(json)")
            return ""
        }
        #expect(parsed.values.isEmpty)
        return problems.map { "\($0.key) \($0.reason)" }.joined()
    }
    #expect(
        try reason(
            #"{"browser.trackTable": {"columns": [{"column": "title", "width": 90, "x": 1}],"#
                + #" "sortColumn": "title", "sortAscending": true}}"#
        ).contains("columns[0].x: unknown key"))
    #expect(
        try reason(
            #"{"browser.trackTable": {"columns": [{"column": "title", "width": 90}],"#
                + #" "sortColumn": "title", "sortAscending": true, "extra": 1}}"#
        ).contains("extra: unknown key"))
    #expect(
        try reason(
            #"{"browser.trackTable": {"columns": [{"column": "bogus", "width": 90}],"#
                + #" "sortColumn": "title", "sortAscending": true}}"#
        ).contains("browser.trackTable"))
    #expect(
        try reason(#"{"window.frame": {"x": 0, "y": 0, "width": 9, "height": 9, "z": 0}}"#)
            .contains("z: unknown key"))
}

/// A key this build doesn't have, or a value that doesn't match, is dropped and reported, and the
/// rest of the layout is kept: a removed key once reset the whole window layout.
@Test func aStateFileKeepsWhatMatchesAndDropsAndReportsTheRest() throws {
    let url = temporaryFile()
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(
        #"{"window.sidebarWidth": 250, "window.old": 1, "window.queueWidth": "wide"}"#.utf8
    ).write(to: url)
    let state = try StateStore(AppState(), fileURL: url)
    #expect(state[\.sidebarWidth] == 250)
    #expect(state[\.queueWidth] == AppState().queueWidth.defaultValue)
    #expect(state.discardReason?.contains("window.old") == true)
    #expect(state.discardReason?.contains("window.queueWidth") == true)
    try state.set(\.queueVisible, to: !AppState().queueVisible.defaultValue)
    let saved = try StateStore(AppState(), fileURL: url)
    #expect(saved.discardReason == nil)
    #expect(saved[\.sidebarWidth] == 250)
    // Half-written, as a crash mid-write on a volume without atomic renames would leave it.
    try Data(#"{"window.sidebarWidth": 2"#.utf8).write(to: url)
    #expect(try StateStore(AppState(), fileURL: url).discardReason != nil)
    try state.set(\.sidebarWidth, to: 300)
    #expect(try StateStore(AppState(), fileURL: url).discardReason == nil)
}

@Test func paletteVisitsSurviveAReloadAndRejectUnknownKeys() throws {
    let url = temporaryFile()
    let state = try StateStore(AppState(), fileURL: url)
    let log = VisitLog(visits: [
        VisitLog.Visit(key: "album:7", count: 3, lastSeconds: 100),
        VisitLog.Visit(key: "artist:Abba", count: 1, lastSeconds: 50),
    ])
    try state.set(\.paletteVisits, to: log)
    #expect(try StateStore(AppState(), fileURL: url)[\.paletteVisits] == log)
    #expect(
        try parse(
            Data(#"{"palette.visits": [{"key": "a", "count": 1, "lastSeconds": 0, "x": 1}]}"#.utf8),
            path: url.path, settings: keyed(AppState())
        ).dropped != nil)
    let unsorted = VisitLog(visits: log.visits.reversed())
    #expect(throws: SettingsError.self) { try state.set(\.paletteVisits, to: unsorted) }
}

@Test func aSaveThatDidntFinishLeavesNothingAtTheNextStart() throws {
    let url = temporaryFile()
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let leftover = url.path + ".sb-c222b5e5-9ngxFq"
    try Data("{".utf8).write(to: URL(fileURLWithPath: leftover))
    #expect(leftoverAtomicWrites(beside: url) == [leftover])
    _ = try StateStore(AppState(), fileURL: url)
    #expect(leftoverAtomicWrites(beside: url).isEmpty)
}

@Test func aNetworkFolderPollsHourlyUnlessSetAsRarelyAsDaily() {
    let folder = WatchedFolder(path: "/Volumes/Music", kind: .network)
    #expect(folder.pollIntervalMinutes == 60)
    var daily = folder
    daily.pollIntervalMinutes = 1440
    #expect(daily.problem() == nil)
    daily.pollIntervalMinutes = 1441
    #expect(daily.problem() == "pollIntervalMinutes 1441 is outside 1...1440")
}

@Test func aNetworkFolderSetToNeverIsWrittenAsNullAndReadBack() throws {
    let never = WatchedFolder(path: "/Volumes/Music", kind: .network, pollIntervalMinutes: nil)
    #expect(never.problem() == nil)
    let text = jsonText([never])
    #expect(text.contains(#""pollIntervalMinutes" : null"#))
    let back = try JSONDecoder().decode([WatchedFolder].self, from: Data(text.utf8))
    #expect(back == [never])
    // Left out is still a problem: every key but the share is written.
    let missing = #"[{"path": "/m", "kind": "network", "include": [], "exclude": []}]"#
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode([WatchedFolder].self, from: Data(missing.utf8))
    }
}

// A column showing All has no selection; it's written as null so it reads back, rather than left
// out, which reset the whole window layout at the next launch.
@Test func browserColumnsShowingAllReadBackAfterASave() throws {
    let url = temporaryFile()
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let columns = [
        BrowserColumn(grouping: .genres, selection: nil),
        BrowserColumn(grouping: .artists, selection: "Arvo Pärt"),
        BrowserColumn(grouping: .albums, selection: nil),
    ]
    try StateStore(AppState(), fileURL: url).set(\.browserColumns, to: columns)
    let reloaded = try StateStore(AppState(), fileURL: url)
    #expect(reloaded.discardReason == nil)
    #expect(reloaded[\.browserColumns] == columns)
}

@Test func browserColumnsMustBeOneToSixDifferentKnownGroupings() throws {
    let url = temporaryFile()
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    func state(_ columns: String) throws -> StateStore<AppState> {
        try Data(#"{"window.sidebarWidth": 250, "browser.columns": \#(columns)}"#.utf8).write(
            to: url)
        return try StateStore(AppState(), fileURL: url)
    }
    let good = try state(
        #"[{"grouping": "years", "selection": "1999"}, {"grouping": "genres", "selection": null},"#
            + #" {"grouping": "composers", "selection": null}]"#)
    #expect(good.discardReason == nil)
    #expect(good[\.browserColumns].map(\.grouping) == [.years, .genres, .composers])
    #expect(good[\.browserColumns][0].selection == "1999")
    for (columns, problem) in [
        (
            #"[{"grouping": "genres", "selection": null}, {"grouping": "genres", "selection": null},"#
                + #" {"grouping": "albums", "selection": null}]"#, "genres is listed twice"
        ),
        (#"[]"#, "0 columns"),
        (
            #"[{"grouping": "moods", "selection": null}, {"grouping": "genres", "selection": null},"#
                + #" {"grouping": "albums", "selection": null}]"#, "moods"
        ),
        (
            #"[{"grouping": "years", "selection": null, "width": 3},"#
                + #" {"grouping": "genres", "selection": null},"#
                + #" {"grouping": "albums", "selection": null}]"#, "width"
        ),
    ] {
        let discarded = try state(columns)
        #expect(discarded.discardReason?.contains(problem) == true, "\(columns)")
        #expect(discarded[\.browserColumns] == BrowserColumn.defaults)
        #expect(discarded[\.sidebarWidth] == 250)
    }
}

/// The tagger's layouts are saved and read back by kind of sheet, with the album list's; an
/// unknown key or a size that isn't positive discards the file, as any value that doesn't
/// match (ADR 0136, ADR 0176).
@Test func theTaggerSheetsLayoutsRoundTripAndABadOneIsDiscarded() throws {
    let url = temporaryFile()
    let state = try StateStore(AppState(), fileURL: url)
    #expect(state[\.taggerSheets] == TaggerSheetLayouts())
    let layouts = TaggerSheetLayouts(
        otherReleases: .init(
            width: 1000, height: 520,
            table: TableLayout(
                widths: ["artist": 210, "year": 50], order: ["year", "artist"],
                sortColumn: "year", sortAscending: false)),
        fieldMapping: .init(
            width: 800, height: 400,
            table: TableLayout(
                widths: ["template": 300], order: [], sortColumn: nil, sortAscending: true)),
        albumList: .init(
            paneWidth: 420,
            table: TableLayout(
                widths: ["album": 260], order: ["album", "files"], sortColumn: "files",
                sortAscending: true)))
    try state.set(\.taggerSheets, to: layouts)
    let read = try StateStore(AppState(), fileURL: url)
    #expect(read.discardReason == nil)
    #expect(read[\.taggerSheets] == layouts)

    let table = #"{"widths": {}, "order": [], "sortAscending": true}"#
    let sheet = #"{"width": 900, "height": 480, "table": "# + table
    for (json, problem) in [
        (#"{"discogsTagger.sheets": {"viewRelease": "# + sheet + #", "x": 1}}}"#, "x: unknown key"),
        (#"{"discogsTagger.sheets": {"other": "# + sheet + "}}}", "other: unknown key"),
        (
            #"{"discogsTagger.sheets": {"viewChanges": {"width": -5, "height": 480,"#
                + #" "table": "# + table + "}}}", "size isn't positive"
        ),
        (
            #"{"discogsTagger.sheets": {"albumList": {"paneWidth": 0, "table": "# + table
                + "}}}", "album list's width isn't positive"
        ),
        (
            #"{"discogsTagger.sheets": {"albumList": {"paneWidth": 300, "table":"#
                + #" {"widths": {"album": -1}, "order": [], "sortAscending": true}}}}"#,
            "column's width isn't positive"
        ),
        (
            #"{"discogsTagger.sheets": {"otherReleases": {"width": 900, "height": 480, "table":"#
                + #" {"widths": {}, "order": ["year", "artist", "year"], "sortAscending": true}}}}"#,
            "named twice in the order"
        ),
    ] {
        try Data(json.utf8).write(to: url)
        let discarded = try StateStore(AppState(), fileURL: url)
        #expect(discarded.discardReason?.contains(problem) == true, "\(json)")
        #expect(discarded[\.taggerSheets] == TaggerSheetLayouts())
    }
}

@Test func savedColumnsTakeTheConfigsGroupingsAndKeepOnlySelectionsMadeInThem() {
    let saved = [
        BrowserColumn(grouping: .years, selection: "1999"),
        BrowserColumn(grouping: .genres, selection: "Jazz"),
        BrowserColumn(grouping: .albums, selection: "Kind of Blue"),
    ]
    // No groupings in the config: the state file's columns as they were.
    #expect(BrowserColumn.restored(saved, groupings: nil) == saved)
    #expect(
        BrowserColumn.restored(saved, groupings: [.years, .artists, .genres]) == [
            BrowserColumn(grouping: .years, selection: "1999"),
            BrowserColumn(grouping: .artists, selection: nil),
            BrowserColumn(grouping: .genres, selection: nil),
        ])
}
