import AppKit
import Foundation
import Testing

@testable import Settings
@testable import SettingsWindow

private struct Schema: SettingsSchema {
    let parts = Setting("a.parts", title: "Parts", parts: [StatusPart.totals], "Parts.")
}

/// A model over a dictionary standing in for the config file, and the dictionary.
@MainActor
private func model(_ parts: [String]) -> (GeneralModel, () -> [String: Any]) {
    nonisolated(unsafe) var values: [String: Any] = ["a.parts": parts]
    let model = GeneralModel(
        settings: Schema().settings, value: { values[$0] },
        set: { key, json in values[key] = json })
    return (model, { values })
}

@MainActor @Test func aListOfChoicesIsAChecklistOfTheHeldOnesThenTheRest() throws {
    let (model, values) = model(["seek", "art"])
    guard case .checklist(let choices) = model.rows.first?.control else {
        Issue.record("not a checklist: \(String(describing: model.rows.first?.control))")
        return
    }
    #expect(choices.map(\.rawValue) == StatusPart.allCases.map(\.rawValue))
    let items = model.checklist("a.parts")
    #expect(items.map(\.choice.rawValue) == ["seek", "art", "track", "format", "totals"])
    #expect(items.map(\.isOn) == [true, true, false, false, false])

    var changed = items
    changed[3].isOn = true
    changed.swapAt(0, 1)
    try model.setChecklist("a.parts", changed)
    #expect(values()["a.parts"] as? [String] == ["art", "seek", "format"])
}

@MainActor @Test func theChecklistMovesARowToTheGapItWasDroppedIn() {
    let list = ChecklistView(title: "Parts")
    let (model, _) = model(["art", "track", "seek"])
    list.items = model.checklist("a.parts")
    var reported: [[String]] = []
    list.changed = { reported.append($0.map(\.choice.rawValue)) }
    list.move(from: 0, to: 3)
    list.move(from: 2, to: 0)
    // Dropped where it already is.
    list.move(from: 1, to: 1)
    list.move(from: 1, to: 2)
    #expect(
        reported == [
            ["track", "seek", "art", "format", "totals"],
            ["seek", "art", "track", "format", "totals"],
        ])
}

@Test func theStatusBarListsEachPartOnce() throws {
    let settings = AppSettings()
    #expect(settings.statusBarParts.validate([.art, .seek, .totals]) == nil)
    #expect(settings.statusBarParts.validate([.art, .seek, .art]) != nil)
}
