import AppKit
import Foundation
import Testing

@testable import Settings
@testable import SettingsWindow

/// A schema with one setting of each kind the General pane draws, none of which has UI code.
private struct Schema: SettingsSchema {
    let flag = Setting("a.flag", title: "Flag", default: false, "A bool.")
    let count = Setting("a.count", title: "Count", default: 5, range: 1...10, "An integer.")
    let limit = Setting<Int?>("a.limit", title: "Limit", default: nil, range: 1...9, "Or null.")
    let gain = Setting("a.gain", title: "Gain", default: 0.5, range: 0...1, "A number.")
    let name = Setting("a.name", title: "Name", default: "x", "A string.")
    let look = Setting("a.look", title: "Look", default: Appearance.auto, "A choice.")
    let folders = Setting<[WatchedFolder]>("a.folders", title: "Folders", default: [], "Folders.")
}

/// A model over a dictionary standing in for the config file, and the dictionary.
@MainActor
private func model() -> (GeneralModel, () -> [String: Any]) {
    nonisolated(unsafe) var values: [String: Any] = [
        "a.flag": false, "a.count": 5, "a.limit": NSNull(), "a.gain": 0.5, "a.name": "x",
        "a.look": "auto", "a.folders": [Any](),
    ]
    let model = GeneralModel(
        settings: Schema().settings, value: { values[$0] },
        set: { key, json in values[key] = json })
    return (model, { values })
}

@MainActor
private func actions(
    addFolder: @escaping () -> Void = {}, removeFolder: @escaping (Int) -> Void = { _ in }
) -> SettingsActions {
    SettingsActions(
        openConfigFile: {}, revealConfigFile: {}, copyDefaultConfig: {}, chooseSyncFolder: {},
        addFolder: addFolder, removeFolder: removeFolder, rescanNow: {})
}

private var appearanceChoices: [SettingKind.Choice] {
    guard case .choice(let choices) = Appearance.kind else { preconditionFailure() }
    return choices
}

@MainActor @Test func theRowsComeFromTheSchemaInOrder() {
    let (model, _) = model()
    #expect(model.rows.map(\.key) == Schema().settings.map(\.key))
    #expect(
        model.rows.map(\.control) == [
            .checkbox,
            .number(whole: true, optional: false),
            .number(whole: true, optional: true),
            .number(whole: false, optional: false),
            .text(optional: false),
            .popUp(appearanceChoices),
            .folders,
        ])
    #expect(model.rows[0].title == "Flag")
    #expect(model.rows[0].summary == "A bool.")
}

@MainActor @Test func everyAppSettingHasARow() {
    let model = GeneralModel(
        settings: AppSettings().settings, value: { _ in nil }, set: { _, _ in })
    #expect(model.rows.count == AppSettings().settings.count)
    #expect(!model.rows.contains { $0.control == .readOnly })
    let appearance = model.rows.first { $0.key == AppSettings().appearance.key }
    #expect(appearance?.control == .popUp(appearanceChoices))
}

@MainActor @Test func valuesReadAndWriteAsJSONHoldsThem() throws {
    let (model, values) = model()
    #expect(!model.isOn("a.flag"))
    try model.setOn("a.flag", true)
    #expect(model.isOn("a.flag"))
    try model.setChoice("a.look", "dark")
    #expect(model.choice("a.look") == "dark")
    #expect(model.text("a.count") == "5")
    #expect(model.text("a.limit") == "")
    try model.setText("a.count", " 7 ")
    #expect(values()["a.count"] as? Int == 7)
    try model.setText("a.limit", "")
    #expect(values()["a.limit"] is NSNull)
    try model.setText("a.gain", "0.25")
    #expect(values()["a.gain"] as? Double == 0.25)
    try model.setText("a.name", "y")
    #expect(model.text("a.name") == "y")
}

@MainActor @Test func textThatIsntANumberThrowsNamingTheSetting() {
    let (model, values) = model()
    #expect(throws: ConfigProblem(line: nil, message: #"Count needs a whole number, not "2.5""#)) {
        try model.setText("a.count", "2.5")
    }
    #expect(throws: ConfigProblem(line: nil, message: #"Gain needs a number, not "half""#)) {
        try model.setText("a.gain", "half")
    }
    #expect(values()["a.count"] as? Int == 5)
}

/// A model whose watched folders are a local folder, a folder on a share and a whole share.
@MainActor
private func modelWithFolders() -> GeneralModel {
    GeneralModel(
        settings: Schema().settings,
        value: {
            $0 == "a.folders"
                ? [
                    ["path": "/Music", "kind": "local", "pollIntervalMinutes": 60],
                    [
                        "path": "library", "share": "smb://nas/music", "kind": "network",
                        "pollIntervalMinutes": 30,
                    ],
                    [
                        "path": "", "share": "smb://nas/other", "kind": "network",
                        "pollIntervalMinutes": 5,
                    ],
                ] : nil
        },
        set: { _, _ in })
}

@MainActor @Test func theWatchedFoldersAreListedWithTheirKindAndRescans() {
    let (model, _) = model()
    #expect(model.folders("a.folders").isEmpty)
    #expect(
        modelWithFolders().folders("a.folders") == [
            .init(location: "/Music", kind: "Local", rescans: "On change"),
            .init(location: "library on smb://nas/music", kind: "Network", rescans: "Every 30 min"),
            .init(location: "smb://nas/other", kind: "Network", rescans: "Every 5 min"),
        ])
}

@MainActor @Test func theWatchedFoldersHaveAPaneOfTheirOwn() throws {
    var removed: [Int] = []
    var added = 0
    let pane = FoldersPane(
        model: modelWithFolders(),
        actions: actions(addFolder: { added += 1 }, removeFolder: { removed.append($0) }))
    _ = pane.view
    #expect(pane.table.numberOfRows == 3)
    #expect(!pane.removeButton.isEnabled)
    pane.table.selectRowIndexes([1], byExtendingSelection: false)
    #expect(pane.removeButton.isEnabled)
    pane.removeButton.performClick(nil)
    #expect(removed == [1])
    func button(_ title: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == title { return button }
        return view.subviews.lazy.compactMap { button(title, in: $0) }.first
    }
    try #require(button("Add…", in: pane.view)).performClick(nil)
    #expect(added == 1)
}

@MainActor @Test func theAppSettingsSitInNamedSectionsWithoutTheWatchedFolders() {
    let model = GeneralModel(
        settings: AppSettings().settings, value: { _ in nil }, set: { _, _ in })
    let sections = model.sections
    #expect(sections.map(\.section) == [.playback, .library, .receiver, .appearance])
    let listed = sections.flatMap(\.rows).map(\.key)
    #expect(listed.count == AppSettings().settings.count - 1)
    #expect(!listed.contains(AppSettings().watchedFolders.key))
    #expect(model.foldersRow?.key == AppSettings().watchedFolders.key)
}

@MainActor @Test func aRefusedValueIsPutBackInItsField() throws {
    let (model, values) = model()
    let pane = GeneralPane(
        model: model, configPath: "/tmp/config.json",
        actions: actions())
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 700, height: 700), styleMask: [.titled],
        backing: .buffered, defer: false)
    window.contentView = pane.view
    func find(_ view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.identifier?.rawValue == "a.count" {
            return field
        }
        return view.subviews.lazy.compactMap(find).first
    }
    let field = try #require(find(pane.view))
    #expect(window.makeFirstResponder(field))
    let editor = try #require(field.currentEditor() as? NSTextView)
    editor.string = "2.5"
    // Return ends the edit but leaves the field being edited.
    pane.controlTextDidEndEditing(
        Notification(name: NSControl.textDidEndEditingNotification, object: field))
    #expect(field.stringValue == "5")
    #expect(values()["a.count"] as? Int == 5)
}

@MainActor @Test func theSyncFolderShowsWhereItIsAndClears() throws {
    var stored: Any? = ["path": "sync", "share": "smb://nas/music"]
    let model = GeneralModel(
        settings: AppSettings().settings, value: { $0 == "sync.folder" ? stored : nil },
        set: { key, json in
            #expect(key == "sync.folder")
            stored = json
        })
    #expect(model.rows.first { $0.key == "sync.folder" }?.control == .syncFolder)
    #expect(model.syncFolder("sync.folder") == "sync on smb://nas/music")
    try model.clear("sync.folder")
    #expect(stored is NSNull)
    #expect(model.syncFolder("sync.folder") == nil)
}
@Test func everySettingSaysWhatItDoesInOneShortSentence() {
    for setting in AppSettings().settings {
        let words = setting.summary.split(separator: " ")
        #expect(words.count <= 12, "\(setting.key): \(setting.summary)")
        #expect(setting.summary.hasSuffix("."), "\(setting.key)")
        #expect(!setting.summary.dropLast().contains(". "), "\(setting.key): one sentence")
    }
}
