import AppKit
import Commands
import Discogs
import Foundation
import Testing

@testable import Settings
@testable import SettingsWindow

/// The pane over a dictionary standing in for the config file, which holds One to one, and the
/// dictionary.
@MainActor
private func pane() -> (TaggingPane, () -> [String: Any]) {
    nonisolated(unsafe) var values: [String: Any] = [
        TaggingModel.setting.key: try! JSONSerialization.jsonObject(
            with: Data(TaggingModel.setting.text(DiscogsPreset.oneToOne.mapping).utf8))
    ]
    let pane = TaggingPane(
        model: TaggingModel(
            value: { values[$0] }, set: { key, json in values[key] = json }, isBlocked: { false }))
    _ = pane.view
    return (pane, { values })
}

/// The text a table shows at `row` in the column titled `title`.
@MainActor
private func text(_ table: NSTableView, _ title: String, _ row: Int) -> String? {
    let column = table.column(withIdentifier: NSUserInterfaceItemIdentifier(title))
    let view = table.view(atColumn: column, row: row, makeIfNecessary: true)
    return (view as? NSTextField)?.stringValue
}

@MainActor
private func select(_ field: DiscogsField, in pane: TaggingPane) {
    pane.fieldsTable.selectRowIndexes(
        [TaggingModel.fields.firstIndex(of: field)!], byExtendingSelection: false)
}

@MainActor @Test func theTableListsEachFieldByItsKeyWithItsRule() throws {
    let (pane, _) = pane()
    #expect(pane.fieldsTable.numberOfRows == DiscogsField.allCases.count)
    #expect(pane.fieldsTable.tableColumns.map(\.title) == ["Field", "Rule"])
    let artist = try #require(TaggingModel.fields.firstIndex(of: .artist))
    #expect(text(pane.fieldsTable, TaggingPane.fieldTitle, artist) == DiscogsField.artist.title)
    let cell = pane.fieldsTable.view(atColumn: 0, row: artist, makeIfNecessary: true)
    #expect(cell?.toolTip == "“artist” in config.json")
    #expect(text(pane.fieldsTable, TaggingPane.ruleTitle, artist) == "Replace Tag · artist")
    #expect(pane.saveButton.isEnabled == false)
    #expect(pane.revertButton.isEnabled == false)
    #expect(pane.problemLabel.isHidden)
}

@MainActor @Test func choosingAPartEditsTheSelectedRuleAndSaveWritesIt() throws {
    let (pane, values) = pane()
    select(.albumArtist, in: pane)
    #expect(pane.ruleHeading.stringValue == "Rule for “\(DiscogsField.albumArtist.title)”")
    #expect(text(pane.tagsTable, "vorbis", 0) == "albumArtist")
    let suffixes = pane.popUp(.suffixes)
    #expect(suffixes.indexOfSelectedItem == 0)
    suffixes.selectItem(at: 1)
    _ = suffixes.target?.perform(suffixes.action, with: suffixes)
    let row = try #require(TaggingModel.fields.firstIndex(of: .albumArtist))
    #expect(
        text(pane.fieldsTable, TaggingPane.ruleTitle, row)
            == "Replace Tag · albumArtist · Drop “(2)”")
    #expect(pane.saveButton.isEnabled)
    pane.save()
    #expect(!pane.saveButton.isEnabled)
    let saved = try TaggingModel.setting.value(
        fromText: String(
            decoding: try JSONSerialization.data(
                withJSONObject: try #require(values()[TaggingModel.setting.key])),
            as: UTF8.self))
    #expect(saved[.albumArtist].format.suffixes == .drop)
}

@MainActor @Test func theProblemShowsAsTheJoinIsTypedAndRevertPutsItBack() throws {
    let (pane, _) = pane()
    select(.genres, in: pane)
    #expect(pane.joinField.stringValue == ", ")
    pane.joinField.stringValue = ""
    pane.controlTextDidChange(
        Notification(name: NSControl.textDidChangeNotification, object: pane.joinField))
    #expect(!pane.problemLabel.isHidden)
    #expect(pane.problemLabel.stringValue.contains("genres is a list, so it needs a join"))
    #expect(!pane.saveButton.isEnabled)
    #expect(pane.revertButton.isEnabled)
    pane.revert()
    #expect(pane.problemLabel.isHidden)
    #expect(pane.joinField.stringValue == ", ")
}

@MainActor @Test func aTagAddedNeedsANameAndOneRemovedGoes() throws {
    let (pane, _) = pane()
    select(.country, in: pane)
    #expect(pane.tagsTable.numberOfRows == 1)
    pane.addTag()
    #expect(pane.tagsTable.numberOfRows == 2)
    #expect(!pane.problemLabel.isHidden)
    pane.tagsTable.abortEditing()
    pane.tagsTable.selectRowIndexes([1], byExtendingSelection: false)
    #expect(pane.removeTagButton.isEnabled)
    pane.removeTag()
    #expect(pane.tagsTable.numberOfRows == 1)
    #expect(pane.problemLabel.isHidden)
    #expect(!pane.model.isEdited)
}

@MainActor @Test func aChangeInTheFileShowsUnlessTheDraftIsEdited() throws {
    nonisolated(unsafe) var values: [String: Any] = [:]
    func store(_ mapping: DiscogsMapping) {
        values[TaggingModel.setting.key] = try! JSONSerialization.jsonObject(
            with: Data(TaggingModel.setting.text(mapping).utf8))
    }
    store(DiscogsPreset.oneToOne.mapping)
    let pane = TaggingPane(
        model: TaggingModel(
            value: { values[$0] }, set: { key, json in values[key] = json }, isBlocked: { false }))
    _ = pane.view
    select(.artist, in: pane)
    store(DiscogsPreset.yate.mapping)
    pane.reload()
    #expect(pane.model.draft == DiscogsPreset.yate.mapping)
    #expect(pane.field == .artist)
    #expect(pane.popUp(.suffixes).indexOfSelectedItem == 1, "YATE drops the (2)")
    #expect(pane.noteLabel.isHidden)
    pane.model.draft[.barcode].mode = .off
    store(DiscogsPreset.minimal.mapping)
    pane.reload()
    #expect(!pane.noteLabel.isHidden)
    #expect(pane.noteLabel.stringValue == TaggingModel.changedNote)
}

@MainActor @Test func theMappingsSettingOpensTheTaggingPane() throws {
    let general = GeneralModel(
        settings: AppSettings().settings, searcherInstalled: true,
        value: { key in
            key == TaggingModel.setting.key
                ? try! JSONSerialization.jsonObject(
                    with: Data(TaggingModel.setting.text(DiscogsPreset.oneToOne.mapping).utf8))
                : nil
        },
        set: { _, _ in }, isBlocked: { false })
    let bindings = try KeyBindings(
        AppCommands.all(), overrides: [:], rules: AppMenus.rules(appName: "App"))
    let controller = SettingsWindowController(
        general: general,
        shortcuts: ShortcutsModel(bindings: bindings, appName: "App") { _ in },
        configPath: "/tmp/config.json",
        actions: SettingsActions(
            openConfigFile: { Issue.record("the pane shows the mapping") }, revealConfigFile: {},
            copyDefaultConfig: {}, chooseSyncFolder: {}, openSyncFolder: {},
            chooseStagingFolder: {}, addFolder: {}, removeFolder: { _ in }, rescanNow: {},
            rescanFolders: { _ in }, outputs: { [] }, searchOutputs: {}, chooseOutput: { _ in },
            showHealth: {},
            libraryDatabase: {
                LibraryDatabase(
                    indexPath: "/tmp/library.sqlite", indexBytes: 0, snapshots: [],
                    lastProblem: nil)
            },
            revealIndex: {}, backUpNow: {}, restoreSnapshot: { _ in }))
    defer { controller.window.close() }
    #expect(controller.tagging == nil, "made as it's first shown")
    controller.show(setting: TaggingModel.setting.key)
    #expect(controller.window.title == "Tagging")
    #expect(controller.tagging?.isViewLoaded == true)
    #expect(
        controller.window.toolbar?.selectedItemIdentifier
            == NSToolbarItem.Identifier(SettingsWindowController.Pane.tagging.rawValue))
}
