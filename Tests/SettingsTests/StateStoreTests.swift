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

/// The problems a file is rejected with.
private func problems(_ json: String) -> [SettingProblem] {
    do {
        _ = try parse(Data(json.utf8), path: "test.json", settings: keyed(TestSchema()))
    } catch SettingsError.invalid(_, let problems) {
        return problems
    } catch {
        Issue.record("expected SettingsError.invalid, got \(error)")
        return []
    }
    Issue.record("the file was accepted")
    return []
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
    #expect(limits["limit"] as? Int == 4)
    let none = try parse(
        Data(#"{"limit": null}"#.utf8), path: "test.json", settings: keyed(TestSchema()))
    #expect(none.keys.contains("limit"))
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
    #expect {
        try parse(Data(#"{"count": 0}"#.utf8), path: "/x/state.json", settings: keyed(TestSchema()))
    } throws: { error in
        "\(error)" == "/x/state.json: \"count\": 0 is outside 1...10"
    }
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
    #expect(settings[\.hogMode] == true)
    #expect(settings[\.outputDeviceUID] == nil)
    #expect(settings[\.digitalVolume] == false)
}

@Test func digitalVolumeIsOffAndSaysItCostsBitPerfectOutput() {
    let setting = AppSettings().digitalVolume
    #expect(setting.defaultValue == false)
    #expect(setting.summary.contains("ends bit-perfect output"))
}

@Test func theTrackTableAppearanceDefaultsToTheTableAsItWas() throws {
    let settings = try StateStore(AppSettings(), fileURL: temporaryFile())
    #expect(settings[\.columnLines] == false)
    #expect(settings[\.rowLines] == false)
    #expect(settings[\.alternatingRows] == true)
    #expect(settings[\.rowHeight] == .regular)
    #expect(settings[\.artSize] == .thumbnail)
    let keys = AppSettings().settings.map(\.key).filter { $0.hasPrefix("appearance.") }
    #expect(
        keys == [
            "appearance.columnLines", "appearance.rowLines", "appearance.alternatingRows",
            "appearance.rowHeight", "appearance.artSize", "appearance.nowPlaying",
        ])
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

@Test func windowLayoutRejectsUnknownKeysAtEveryLevel() throws {
    func reason(_ json: String) throws -> String {
        let url = temporaryFile()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
        do {
            _ = try parse(Data(contentsOf: url), path: url.path, settings: keyed(AppState()))
        } catch SettingsError.invalid(_, let problems) {
            return problems.map { "\($0.key) \($0.reason)" }.joined()
        }
        Issue.record("accepted \(json)")
        return ""
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

@Test func aStateFileThatDoesntMatchIsDiscardedAndReported() throws {
    let url = temporaryFile()
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"window.sidebarWidth": 250, "window.old": 1}"#.utf8).write(to: url)
    #expect(throws: SettingsError.self) {
        try parse(Data(contentsOf: url), path: url.path, settings: keyed(AppState()))
    }
    let state = try StateStore(AppState(), fileURL: url)
    #expect(state[\.sidebarWidth] == AppState().sidebarWidth.defaultValue)
    #expect(state.discardReason?.contains("window.old") == true)
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
    #expect(throws: SettingsError.self) {
        try parse(
            Data(#"{"palette.visits": [{"key": "a", "count": 1, "lastSeconds": 0, "x": 1}]}"#.utf8),
            path: url.path, settings: keyed(AppState()))
    }
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
