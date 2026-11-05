import AppKit
import Commands
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
        settings: Schema().settings, searcherInstalled: true, value: { values[$0] },
        set: { key, json in values[key] = json }, isBlocked: { false })
    return (model, { values })
}

@MainActor
private func actions(
    openConfigFile: @escaping () -> Void = {}, chooseSyncFolder: @escaping () -> Void = {},
    openSyncFolder: @escaping () -> Void = {},
    addFolder: @escaping () -> Void = {}, removeFolder: @escaping (Int) -> Void = { _ in },
    rescanNow: @escaping () -> Void = {}, rescanFolders: @escaping ([Int]) -> Void = { _ in },
    outputs: @escaping () -> [OutputOption] = { [] },
    chooseOutput: @escaping (OutputChoice) -> Void = { _ in }
) -> SettingsActions {
    SettingsActions(
        openConfigFile: openConfigFile, revealConfigFile: {}, copyDefaultConfig: {},
        chooseSyncFolder: chooseSyncFolder, openSyncFolder: openSyncFolder, addFolder: addFolder,
        removeFolder: removeFolder, rescanNow: rescanNow,
        rescanFolders: rescanFolders, outputs: outputs,
        searchOutputs: {}, chooseOutput: chooseOutput)
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

@MainActor @Test func everyAppSettingButTheConfigFileOnesHasARow() {
    let schema = AppSettings()
    let model = GeneralModel(
        settings: schema.settings, searcherInstalled: true, value: { _ in nil }, set: { _, _ in },
        isBlocked: { false })
    #expect(
        model.rows.map(\.key)
            == schema.settings.map(\.key).filter { $0 != schema.networkScanReaders.key })
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

/// A model whose watched folders are a local folder, a folder on a share and a whole share,
/// and the folders as the config file has them after any change.
@MainActor
private func modelWithFoldersAndValues() -> (GeneralModel, () -> [[String: Any]]) {
    nonisolated(unsafe) var folders: [[String: Any]] = [
        ["path": "/Music", "kind": "local", "pollIntervalMinutes": 60],
        [
            "path": "library", "share": "smb://nas/music", "kind": "network",
            "pollIntervalMinutes": 30,
        ],
        [
            "path": "", "share": "smb://nas/other", "kind": "network",
            "pollIntervalMinutes": 5,
        ],
    ]
    let model = GeneralModel(
        settings: Schema().settings, searcherInstalled: true,
        value: { $0 == "a.folders" ? folders : nil },
        set: { key, json in
            if key == "a.folders", let json = json as? [[String: Any]] { folders = json }
        }, isBlocked: { false })
    return (model, { folders })
}

@MainActor
private func modelWithFolders() -> GeneralModel { modelWithFoldersAndValues().0 }

@MainActor @Test func theWatchedFoldersAreListedWithTheirKindAndRescans() {
    let (model, _) = model()
    #expect(model.folders("a.folders").isEmpty)
    #expect(
        modelWithFolders().folders("a.folders") == [
            .init(location: "/Music", kind: "Local", rescans: "On change"),
            .init(
                location: "library on smb://nas/music", kind: "Network", rescans: "Every 30 min",
                interval: .every(minutes: 30)),
            .init(
                location: "smb://nas/other", kind: "Network", rescans: "Every 5 min",
                interval: .every(minutes: 5)),
        ])
}

@MainActor @Test func theRescanIntervalsStayInTheSchemasRange() {
    let range = WatchedFolder.pollIntervalRangeMinutes
    #expect(GeneralModel.rescanIntervalsMinutes.first == range.lowerBound)
    #expect(GeneralModel.rescanIntervalsMinutes.last == range.upperBound)
    #expect(GeneralModel.rescanIntervalsMinutes == GeneralModel.rescanIntervalsMinutes.sorted())
    #expect(GeneralModel.rescansText(.every(minutes: 60)) == "Every hour")
    #expect(GeneralModel.rescansText(.every(minutes: 1440)) == "Every 24 hours")
    #expect(GeneralModel.rescansText(.every(minutes: 90)) == "Every 90 min")
    #expect(GeneralModel.rescansText(.never) == "Never")
    let odd = GeneralModel.Folder(
        location: "x", kind: "Network", rescans: "", interval: .every(minutes: 45))
    #expect(GeneralModel.rescanChoices(odd).contains(.every(minutes: 45)))
    #expect(GeneralModel.rescanChoices(odd).last == .never)
}

@MainActor @Test func theRescansColumnSetsANetworkFoldersInterval() throws {
    let (model, folders) = modelWithFoldersAndValues()
    let pane = FoldersPane(model: model, actions: actions())
    _ = pane.view
    let column = try #require(pane.table.tableColumns.firstIndex { $0.title == "Rescans" })
    let local = pane.table.delegate?.tableView?(
        pane.table, viewFor: pane.table.tableColumns[column], row: 0)
    #expect((local as? NSTextField)?.stringValue == "On change")
    let popUp = try #require(
        pane.table.delegate?.tableView?(
            pane.table, viewFor: pane.table.tableColumns[column], row: 1) as? NSPopUpButton)
    #expect(popUp.titleOfSelectedItem == "Every 30 min")
    #expect(popUp.itemTitles.contains("Every 6 hours"))
    popUp.selectItem(withTitle: "Every 6 hours")
    _ = popUp.sendAction(popUp.action, to: popUp.target)
    #expect(folders()[1]["pollIntervalMinutes"] as? Int == 360)
    #expect(folders()[1]["share"] as? String == "smb://nas/music")
    #expect(folders()[2]["pollIntervalMinutes"] as? Int == 5)
    #expect(model.folders("a.folders")[1].rescans == "Every 6 hours")
    popUp.selectItem(withTitle: "Never")
    _ = popUp.sendAction(popUp.action, to: popUp.target)
    #expect(folders()[1]["pollIntervalMinutes"] is NSNull)
    #expect(model.folders("a.folders")[1].interval == .never)
    pane.reload()
    let never = try #require(
        pane.table.delegate?.tableView?(
            pane.table, viewFor: pane.table.tableColumns[column], row: 1) as? NSPopUpButton)
    #expect(never.titleOfSelectedItem == "Never")
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

@MainActor @Test func theSelectedFoldersAreRescannedFromAButtonOrTheContextMenu() throws {
    var rescanned: [[Int]] = []
    var all = 0
    let pane = FoldersPane(
        model: modelWithFolders(),
        actions: actions(rescanNow: { all += 1 }, rescanFolders: { rescanned.append($0) }))
    _ = pane.view
    #expect(!pane.rescanButton.isEnabled)
    pane.table.selectRowIndexes([0, 2], byExtendingSelection: false)
    #expect(pane.rescanButton.isEnabled)
    #expect(!pane.removeButton.isEnabled, "Remove takes one folder")
    pane.rescanButton.performClick(nil)
    #expect(rescanned == [[0, 2]])

    let menu = try #require(pane.table.menu)
    #expect(menu.items.map(\.title) == ["Rescan", "Rescan All"])
    for item in menu.items {
        #expect(pane.validateMenuItem(item))
        let action = try #require(item.action)
        NSApp.sendAction(action, to: item.target, from: item)
    }
    #expect(rescanned == [[0, 2], [0, 2]])
    #expect(all == 1)
    pane.table.deselectAll(nil)
    #expect(!pane.validateMenuItem(menu.items[0]))
}

@MainActor @Test func withoutSearcherTheFileViewerIsLeftToTheConfigFile() {
    let schema = AppSettings()
    let model = GeneralModel(
        settings: schema.settings, searcherInstalled: false, value: { _ in nil },
        set: { _, _ in }, isBlocked: { false })
    let keys = model.rows.map(\.key)
    #expect(!keys.contains(schema.fileViewer.key))
    #expect(!keys.contains(schema.networkScanReaders.key))
    #expect(keys.contains(schema.groupByAlbumArtist.key))
}

@MainActor @Test func theAppSettingsSitInNamedSectionsWithoutTheWatchedFolders() {
    let schema = AppSettings()
    let model = GeneralModel(
        settings: schema.settings, searcherInstalled: true, value: { _ in nil }, set: { _, _ in },
        isBlocked: { false })
    let sections = model.sections
    #expect(
        sections.map(\.section) == [
            .output, .playCounts, .library, .sync, .receiver, .networkFolders, .appearance,
        ])
    #expect(
        sections.first { $0.section == .networkFolders }?.rows.map(\.key) == [
            schema.pausePollingDuringPlayback.key, schema.rescanNetworkFoldersAtLaunch.key,
        ])
    #expect(
        sections.first { $0.section == .playCounts }?.rows.map(\.key) == [schema.playedPercent.key])
    // The toolbar is above the status bar in the window, so its layout's row comes first.
    let appearance = sections.first { $0.section == .appearance }?.rows.map(\.key) ?? []
    #expect(
        appearance.suffix(4) == [
            schema.headerStatusLayout.key, schema.headerTitleFormat.key, schema.statusBarStyle.key,
            schema.statusBarLayout.key,
        ])
    let titleFormat = model.rows.first { $0.key == schema.headerTitleFormat.key }
    // It's a template like the window's title, with the same tokens.
    let windowTitle = model.rows.first { $0.key == schema.windowTitle.key }
    #expect(titleFormat?.control != nil && titleFormat?.control == windowTitle?.control)
    let listed = sections.flatMap(\.rows).map(\.key)
    #expect(listed.count == AppSettings().settings.count - 3)
    #expect(!listed.contains(AppSettings().watchedFolders.key))
    // The output device's row picks the renderer too.
    #expect(!listed.contains(AppSettings().outputRenderer.key))
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

@MainActor @Test func theOutputDeviceIsPickedFromTheOutputsFound() throws {
    let schema = AppSettings()
    var stored: [String: Any] = [schema.outputDeviceUID.key: "USB-9"]
    var options = outputOptions(
        devices: [FoundOutput(id: "Speakers", name: "Speakers")],
        renderers: [FoundOutput(id: "uuid:denon", name: "Denon")], current: .device(uid: "USB-9"))
    var chosen: [OutputChoice] = []
    let model = GeneralModel(
        settings: schema.settings, searcherInstalled: true, value: { stored[$0] },
        set: { key, json in stored[key] = json }, isBlocked: { false })
    #expect(model.rows.first { $0.key == schema.outputDeviceUID.key }?.control == .output)
    let pane = GeneralPane(
        model: model, configPath: "/tmp/config.json",
        actions: actions(outputs: { options }, chooseOutput: { chosen.append($0) }))
    func find(_ view: NSView) -> NSPopUpButton? {
        if let popUp = view as? NSPopUpButton,
            popUp.identifier?.rawValue == schema.outputDeviceUID.key
        {
            return popUp
        }
        return view.subviews.lazy.compactMap(find).first
    }
    let popUp = try #require(find(pane.view))
    #expect(popUp.itemTitles == ["System Default", "Speakers", "USB-9 (not connected)", "Denon"])
    #expect(popUp.titleOfSelectedItem == "USB-9 (not connected)")
    popUp.selectItem(at: 3)
    _ = popUp.target?.perform(popUp.action, with: popUp)
    #expect(chosen == [.renderer(udn: "uuid:denon")])
    // A device that comes and a renderer that's chosen show on reload.
    stored[schema.outputRenderer.key] = "uuid:denon"
    options.insert(OutputOption(choice: .device(uid: "Speakers"), title: "Speakers"), at: 1)
    pane.reload()
    #expect(
        popUp.itemTitles == [
            "System Default", "Speakers", "Speakers", "USB-9 (not connected)", "Denon",
        ])
    #expect(popUp.titleOfSelectedItem == "Denon")
}

@MainActor @Test func theReceiversRowsFollowItsSwitch() throws {
    let schema = AppSettings()
    var stored: [String: Any] = [schema.receiverEnabled.key: false]
    let model = GeneralModel(
        settings: schema.settings, searcherInstalled: true, value: { stored[$0] },
        set: { key, json in stored[key] = json }, isBlocked: { false })
    #expect(model.isEnabled(schema.receiverEnabled.key))
    #expect(!model.isEnabled(schema.receiverAddress.key))
    #expect(!model.isEnabled(schema.receiverVolumeKeys.key))
    #expect(model.isEnabled(schema.hogMode.key))
    let receiverRows = model.sections.first { $0.section == .receiver }?.rows.map(\.key)
    #expect(receiverRows?.first == schema.receiverEnabled.key, "the switch comes first")

    let pane = GeneralPane(
        model: model, configPath: nil, actions: actions(), sections: [.receiver])
    let address = try #require(view(schema.receiverAddress.key, in: pane.view) as? NSTextField)
    let volumeKeys = try #require(
        view(schema.receiverVolumeKeys.key, in: pane.view) as? NSButton)
    #expect(!address.isEnabled)
    #expect(!volumeKeys.isEnabled)
    let toggle = try #require(view(schema.receiverEnabled.key, in: pane.view) as? NSButton)
    toggle.performClick(nil)
    #expect(stored[schema.receiverEnabled.key] as? Bool == true)
    #expect(address.isEnabled)
    #expect(volumeKeys.isEnabled)
}

@MainActor @Test func aColorRowIsAWellWithADefaultButton() async throws {
    let schema = AppSettings()
    let key = schema.rowLineColor.key
    var stored: [String: Any] = [key: NSNull()]
    let model = GeneralModel(
        settings: schema.settings, searcherInstalled: true, value: { stored[$0] },
        set: { key, json in stored[key] = json }, isBlocked: { false })
    #expect(model.rows.first { $0.key == key }?.control == .color(optional: true))
    #expect(model.color(key) == nil)
    let pane = GeneralPane(
        model: model, configPath: nil, actions: actions(), sections: [.appearance])
    pane.reload()
    let well = try #require(view(key, in: pane.view) as? NSColorWell)
    let reset = try #require(button("Default", in: pane.view))
    #expect(!reset.isEnabled)
    well.color = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.5)
    _ = well.sendAction(well.action, to: well.target)
    try await waitFor { stored[key] is String }
    #expect(stored[key] as? String == "#FF000080")
    pane.reload()
    #expect(reset.isEnabled)
    #expect(abs((well.color.usingColorSpace(.sRGB)?.alphaComponent ?? 0) - 0.5) < 0.01)
    reset.performClick(nil)
    #expect(stored[key] is NSNull)
}

/// Waits for `condition`, such as a color well's color saved after its pause, for up to 5 s.
@MainActor
private func waitFor(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !condition() {
        guard Date() < deadline else {
            Issue.record("timed out")
            return
        }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
}

/// A color picked in the color panel reaches the setting, once the panel stops changing, and
/// Default then clears it.
@MainActor @Test func aColorPickedInThePanelIsSavedAndDefaultClearsIt() async throws {
    let schema = AppSettings()
    let key = schema.rowLineColor.key
    nonisolated(unsafe) var stored: [String: Any] = [key: NSNull()]
    nonisolated(unsafe) var saves = 0
    nonisolated(unsafe) var pane: GeneralPane?
    let model = GeneralModel(
        settings: schema.settings, searcherInstalled: true, value: { stored[$0] },
        set: { key, json in
            stored[key] = json
            saves += 1
            // The app reloads the pane on every change of the config file.
            pane?.reload()
        }, isBlocked: { false })
    pane = GeneralPane(
        model: model, configPath: nil, actions: actions(), sections: [.appearance])
    let shown = try #require(pane)
    let window = NSWindow(contentViewController: shown)
    window.makeKeyAndOrderFront(nil)
    defer {
        NSColorPanel.shared.close()
        window.close()
    }
    let well = try #require(view(key, in: shown.view) as? NSColorWell)
    let reset = try #require(button("Default", in: shown.view))
    well.activate(true)
    NSColorPanel.shared.color = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.75)
    NSColorPanel.shared.color = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.5)
    try await waitFor { stored[key] is String }
    // Long enough for a second save, if the first step had one of its own.
    try await Task.sleep(nanoseconds: UInt64(GeneralPane.colorPauseSeconds * 1_000_000_000))
    #expect(stored[key] as? String == "#FF000080")
    #expect(saves == 1, "one save for the steps of one change")
    #expect(reset.isEnabled)
    reset.performClick(nil)
    #expect(stored[key] is NSNull)
    #expect(well.color == .gridColor)
    #expect(!reset.isEnabled)
}

@MainActor @Test func aCheckboxCarriesItsTitleAndAFieldItsLabel() throws {
    let (model, _) = model()
    let pane = GeneralPane(
        model: model, configPath: nil, actions: actions())
    let flag = try #require(view("a.flag", in: pane.view) as? NSButton)
    #expect(flag.title == "Flag")
    #expect(labels(in: pane.view).contains("Count:"))
    #expect(!labels(in: pane.view).contains("Flag:"))
}

@MainActor @Test func everyLabelFitsItsColumn() {
    let model = GeneralModel(
        settings: AppSettings().settings, searcherInstalled: true, value: { _ in nil },
        set: { _, _ in }, isBlocked: { false })
    let pane = GeneralPane(
        model: model, configPath: "/tmp/config.json", actions: actions(),
        sections: GeneralModel.Section.allCases)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 700, height: 700), styleMask: [.titled],
        backing: .buffered, defer: false)
    window.contentView = pane.view
    pane.view.layoutSubtreeIfNeeded()
    func fields(_ view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
    }
    for field in fields(pane.view) where !field.isEditable && !field.stringValue.isEmpty {
        let needed =
            field.cell?.cellSize(
                forBounds: NSRect(
                    x: 0, y: 0, width: field.frame.width, height: .greatestFiniteMagnitude)
            ).height ?? 0
        #expect(field.frame.width > 0, "\(field.stringValue)")
        #expect(field.frame.height + 1 >= needed, "\(field.stringValue) is cut off")
        if field.stringValue.hasSuffix(":") {
            #expect(
                field.frame.width + 1 >= field.fittingSize.width,
                "\(field.stringValue) is cut off")
        }
    }
    func buttons(_ view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
    }
    for button in buttons(pane.view) {
        #expect(
            button.frame.width + 1 >= button.fittingSize.width, "\(button.title) is cut off")
        #expect(
            pane.view.convert(button.bounds, from: button).maxX <= GeneralPane.width,
            "\(button.title) is past the pane's edge")
    }
}

@MainActor @Test func theSyncFolderRowNamesTheFolderWithChangeOpenAndClear() throws {
    let schema = AppSettings()
    var stored: Any? = ["path": "machines/sync", "share": "smb://nas._smb._tcp.local/music"]
    var chosen = 0
    var opened = 0
    let model = GeneralModel(
        settings: schema.settings, searcherInstalled: true,
        value: { $0 == schema.syncFolder.key ? stored : nil },
        set: { _, json in stored = json }, isBlocked: { false })
    #expect(model.syncFolderName(schema.syncFolder.key) == "sync")
    let pane = GeneralPane(
        model: model, configPath: nil,
        actions: actions(chooseSyncFolder: { chosen += 1 }, openSyncFolder: { opened += 1 }),
        sections: [.sync])
    _ = pane.view
    #expect(labels(in: pane.view).contains("sync"))
    try #require(button("Change…", in: pane.view)).performClick(nil)
    try #require(button("Open", in: pane.view)).performClick(nil)
    #expect((chosen, opened) == (1, 1))
    try #require(button("Clear", in: pane.view)).performClick(nil)
    #expect(stored is NSNull)
    pane.reload()
    #expect(labels(in: pane.view).contains(noValueText))
    #expect(button("Choose…", in: pane.view) != nil)
    #expect(button("Open", in: pane.view)?.isEnabled == false)

    stored = ["path": "", "share": "smb://nas._smb._tcp.local/music"]
    #expect(model.syncFolderName(schema.syncFolder.key) == "music")
}

@MainActor @Test func thePlayedShareIsAPercentField() throws {
    let schema = AppSettings()
    var stored: [String: Any] = [schema.playedPercent.key: 75]
    let model = GeneralModel(
        settings: schema.settings, searcherInstalled: true, value: { stored[$0] },
        set: { key, json in stored[key] = json }, isBlocked: { false })
    #expect(model.rows.first { $0.key == schema.playedPercent.key }?.unit == "%")
    let pane = GeneralPane(
        model: model, configPath: nil, actions: actions(), sections: [.playCounts])
    let field = try #require(view(schema.playedPercent.key, in: pane.view) as? NSTextField)
    #expect(field.stringValue == "75")
    #expect(labels(in: pane.view).contains("%"))
    try model.setText(schema.playedPercent.key, "90")
    #expect(stored[schema.playedPercent.key] as? Int == 90)
}

@MainActor @Test func theSyncFolderShowsWhereItIsAndClears() throws {
    var stored: Any? = ["path": "sync", "share": "smb://nas/music"]
    let model = GeneralModel(
        settings: AppSettings().settings, searcherInstalled: true,
        value: { $0 == "sync.folder" ? stored : nil },
        set: { key, json in
            #expect(key == "sync.folder")
            stored = json
        }, isBlocked: { false })
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

@MainActor @Test func theAppearanceSettingsHaveAPaneOfTheirOwn() throws {
    let schema = AppSettings()
    let model = GeneralModel(
        settings: schema.settings, searcherInstalled: true, value: { _ in nil }, set: { _, _ in },
        isBlocked: { false })
    let bindings = try KeyBindings(
        AppCommands.all(), overrides: [:], rules: AppMenus.rules(appName: "App"))
    let controller = SettingsWindowController(
        general: model, shortcuts: ShortcutsModel(bindings: bindings, appName: "App") { _ in },
        configPath: "/tmp/config.json", actions: actions())
    func keys(_ view: NSView) -> Set<String> {
        view.subviews.reduce(into: Set(view.identifier.map { [$0.rawValue] } ?? [])) {
            $0.formUnion(keys($1))
        }
    }
    let appearanceKeys = Set(
        schema.settings.map(\.key).filter { GeneralModel.Section(key: $0) == .appearance })
    #expect(appearanceKeys.contains(schema.rowHeight.key))
    #expect(appearanceKeys.contains(schema.appearance.key))
    #expect(appearanceKeys.contains(schema.artSize.key))

    controller.show(setting: schema.rowHeight.key)
    #expect(controller.window.title == "Appearance")
    let appearance = try #require(controller.window.contentViewController?.view)
    #expect(keys(appearance).isSuperset(of: appearanceKeys))
    #expect(!keys(appearance).contains(schema.hogMode.key))

    controller.show(.general)
    let general = try #require(controller.window.contentViewController?.view)
    #expect(keys(general).contains(schema.receiverEnabled.key))
    #expect(keys(general).isDisjoint(with: appearanceKeys))
    #expect(!keys(general).contains(schema.pausePollingDuringPlayback.key))
    #expect(!keys(general).contains(schema.hogMode.key))

    controller.show(setting: schema.playedPercent.key)
    #expect(controller.window.title == "Playback")
    let playback = try #require(controller.window.contentViewController?.view)
    #expect(keys(playback).isSuperset(of: [schema.hogMode.key, schema.playedPercent.key]))
    controller.window.close()
}

@MainActor @Test func thePaletteOpensTheWatchedFoldersPaneOrTheConfigFile() throws {
    let schema = AppSettings()
    var opened = 0
    let model = GeneralModel(
        settings: schema.settings, searcherInstalled: false, value: { _ in nil },
        set: { _, _ in }, isBlocked: { false })
    let bindings = try KeyBindings(
        AppCommands.all(), overrides: [:], rules: AppMenus.rules(appName: "App"))
    let controller = SettingsWindowController(
        general: model, shortcuts: ShortcutsModel(bindings: bindings, appName: "App") { _ in },
        configPath: "/tmp/config.json", actions: actions(openConfigFile: { opened += 1 }))
    controller.show(setting: schema.rescanNetworkFoldersAtLaunch.key)
    #expect(controller.window.title == schema.watchedFolders.title)
    let folders = try #require(controller.window.contentViewController?.view)
    #expect(view(schema.rescanNetworkFoldersAtLaunch.key, in: folders) != nil)
    controller.show(setting: schema.networkScanReaders.key)
    controller.show(setting: schema.fileViewer.key)
    #expect(opened == 2)
    controller.window.close()
}

/// The view with `key` as its identifier, under `view`.
@MainActor
private func view(_ key: String, in view: NSView) -> NSView? {
    if view.identifier?.rawValue == key { return view }
    return view.subviews.lazy.compactMap { SettingsWindowTests.view(key, in: $0) }.first
}

/// The text of every label under `view`.
@MainActor
private func labels(in view: NSView) -> [String] {
    ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap(labels)
}

@MainActor
private func button(_ title: String, in view: NSView) -> NSButton? {
    if let button = view as? NSButton, button.title == title { return button }
    return view.subviews.lazy.compactMap { button(title, in: $0) }.first
}

@MainActor
private func helpButton(in view: NSView) -> NSButton? {
    if let button = view as? NSButton, button.bezelStyle == .helpButton { return button }
    return view.subviews.lazy.compactMap { helpButton(in: $0) }.first
}

/// The window title's row is a text field with a help button, whose tooltip and popover list
/// every token with what it stands for; what's typed is saved as the template.
@MainActor @Test func theWindowTitleRowListsItsTokens() throws {
    let schema = AppSettings()
    let key = schema.windowTitle.key
    nonisolated(unsafe) var saved: [String: Any] = [:]
    let model = GeneralModel(
        settings: schema.settings, searcherInstalled: true, value: { saved[$0] },
        set: { saved[$0] = $1 }, isBlocked: { false })
    let row = try #require(model.rows.first { $0.key == key })
    guard case .template(let tokens) = row.control else {
        Issue.record("\(row.control)")
        return
    }
    let help = GeneralModel.help(tokens)
    for token in TitleToken.allCases {
        #expect(help.contains("\(token.placeholder)  \(token.help)"))
    }
    try model.setText(key, " {album} — {title} ")
    #expect(saved[key] as? String == "{album} — {title}")

    let pane = GeneralPane(
        model: model, configPath: nil, actions: actions(), sections: [.appearance])
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 700, height: 700), styleMask: [.titled],
        backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.contentView = pane.view
    window.orderFront(nil)
    pane.reload()
    let field = try #require(view(key, in: pane.view) as? NSTextField)
    #expect(field.stringValue == "{album} — {title}")
    let button = try #require(helpButton(in: pane.view))
    #expect(button.toolTip == help)
    button.performClick(nil)
    let popover = try #require(pane.tokensPopover)
    #expect(popover.isShown)
    #expect(labels(in: try #require(popover.contentViewController?.view)) == [help])
    popover.close()
}
