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

private func store(_ json: String? = nil) throws -> SettingsStore<TestSchema> {
    let url = temporaryFile()
    if let json {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
    }
    return try SettingsStore(TestSchema(), fileURL: url)
}

private func fileContents(_ store: SettingsStore<TestSchema>) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as! [String: Any]
}

/// The problems a settings file is rejected with.
private func problems(_ json: String) -> [SettingProblem] {
    do {
        _ = try store(json)
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

    let reloaded = try SettingsStore(TestSchema(), fileURL: settings.fileURL)
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
            SettingProblem(key: "count", reason: .wrongType(expected: "an integer", detail: nil)),
            SettingProblem(key: "flag", reason: .wrongType(expected: "true or false", detail: nil)),
            SettingProblem(key: "name", reason: .wrongType(expected: "a string", detail: nil)),
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
    #expect(try store(#"{"limit": 4}"#)[\.limit] == 4)
    #expect(try store(#"{"limit": null}"#)[\.limit] == nil)
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
    let url = temporaryFile()
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"count": 0}"#.utf8).write(to: url)
    #expect {
        try SettingsStore(TestSchema(), fileURL: url)
    } throws: { error in
        "\(error)" == "\(url.path): \"count\": 0 is outside 1...10"
    }
}

@Test func rejectsFilesThatArentAnObject() {
    #expect(throws: SettingsError.self) { try store("[1, 2]") }
    #expect(throws: SettingsError.self) { try store("{") }
}

@Test func setValidatesAndLeavesTheFileAlone() throws {
    let settings = try store()
    try settings.set(\.count, to: 3)
    #expect(throws: SettingsError.self) { try settings.set(\.count, to: 0) }
    #expect(settings[\.count] == 3)
    #expect(try fileContents(settings)["count"] as? Int == 3)
}

@Test func exportHoldsEveryEffectiveValue() throws {
    let settings = try store()
    try settings.set(\.count, to: 8)
    let exported =
        try JSONSerialization.jsonObject(with: settings.exportJSON()) as! [String: Any]
    #expect(exported.keys.sorted() == TestSchema().settings.map(\.key).sorted())
    #expect(exported["count"] as? Int == 8)
    #expect(exported["device"] as? String == "built-in")
}

@Test func importAppliesAFileOnTopOfTheCurrentValues() throws {
    let source = try store()
    try source.set(\.theme, to: .dark)
    try source.set(\.tags, to: ["x"])
    let exportURL = temporaryFile()
    try FileManager.default.createDirectory(
        at: exportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try source.export(to: exportURL)

    let target = try store()
    try target.set(\.count, to: 9)
    #expect(try target.importSettings(from: exportURL) == TestSchema().settings.count)
    #expect(target[\.theme] == .dark)
    #expect(target[\.tags] == ["x"])
    // The export carries the defaults too, so it resets values it doesn't change.
    #expect(target[\.count] == 5)
    #expect(try fileContents(target).keys.sorted() == ["tags", "theme"])
}

@Test func importOfABadFileChangesNothing() throws {
    let target = try store()
    try target.set(\.count, to: 9)
    let url = temporaryFile()
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"count": 2, "colour": "red"}"#.utf8).write(to: url)

    #expect(throws: SettingsError.self) { try target.importSettings(from: url) }
    #expect(target[\.count] == 9)
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
    let settings = try SettingsStore(AppSettings(), fileURL: temporaryFile())
    #expect(settings[\.hogMode] == true)
    #expect(settings[\.outputDeviceUID] == nil)
    #expect(settings[\.digitalVolume] == false)
}

@Test func digitalVolumeIsOffAndSaysItCostsBitPerfectOutput() {
    let setting = AppSettings().digitalVolume
    #expect(setting.defaultValue == false)
    #expect(setting.summary.contains("no longer bit-perfect"))
}

@Test func windowLayoutSurvivesAReloadAndRejectsBadValues() throws {
    let url = temporaryFile()
    let settings = try SettingsStore(AppState(), fileURL: url, mismatch: .discard)
    let layout = TrackTableLayout(
        columns: [
            ColumnLayout(column: .path, width: 300), ColumnLayout(column: .title, width: 90),
        ],
        sortColumn: .dateAdded, sortAscending: false)
    try settings.set(\.trackTable, to: layout)
    try settings.set(\.windowFrame, to: WindowFrame(x: 10, y: 20, width: 800, height: 500))
    let reloaded = try SettingsStore(AppState(), fileURL: url, mismatch: .discard)
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
}

@Test func windowLayoutRejectsUnknownKeysAtEveryLevel() throws {
    func reason(_ json: String) throws -> String {
        let url = temporaryFile()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
        do {
            _ = try SettingsStore(AppState(), fileURL: url)
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

@Test func aStateFileThatDoesntMatchIsDiscarded() throws {
    let url = temporaryFile()
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"window.sidebarWidth": 250, "window.old": 1}"#.utf8).write(to: url)
    #expect(throws: SettingsError.self) { try SettingsStore(AppState(), fileURL: url) }
    let state = try SettingsStore(AppState(), fileURL: url, mismatch: .discard)
    #expect(state[\.sidebarWidth] == AppState().sidebarWidth.defaultValue)
}
