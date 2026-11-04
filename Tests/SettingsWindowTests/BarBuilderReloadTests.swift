import AppKit
import Foundation
import Testing

@testable import Settings
@testable import SettingsWindow

/// A config file stand-in the tests change under the builder: its layout, and whether a
/// problem refuses every change.
@MainActor
private final class StandIn {
    let setting = AppSettings().statusBarLayout
    nonisolated(unsafe) var values: [String: Any] = [:]
    nonisolated(unsafe) var blocked = false
    lazy var model = GeneralModel(
        settings: [setting.descriptor], searcherInstalled: true,
        value: { [unowned self] in values[$0] },
        set: { [unowned self] key, json in
            if case .failure(let reason) = setting.decode(json: json) {
                throw SettingProblem(key: key, reason: reason)
            }
            values[key] = json
        }, isBlocked: { [unowned self] in blocked })

    init(_ layout: BarLayout<StatusPart>) throws { try write(layout) }

    func write(_ layout: BarLayout<StatusPart>) throws {
        values[setting.key] = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(layout))
    }

    func builder() throws -> BarBuilderModel { try model.barBuilder(setting.key) }
}

private func center(_ parts: [StatusPart]) -> BarLayout<StatusPart> {
    BarLayout(center: BarColumn(parts: parts, width: .flexible, alignment: .center))
}

/// A reload that leaves the selected column fewer parts moves the selection onto what's left,
/// so drawing it and the keys don't index past the end.
@MainActor @Test func aReloadKeepsTheSelectionInsideTheColumn() throws {
    let file = try StandIn(center([.track, .seek, .format]))
    let builder = try file.builder()
    builder.select(.init(place: .center, part: 2))
    try file.write(center([.seek]))
    try builder.reload()
    #expect(builder.selection == .init(place: .center, part: 0))
    let view = BarBuilderView(model: builder)
    view.frame = NSRect(x: 0, y: 0, width: 760, height: view.intrinsicContentSize.height)
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    builder.moveSelected(true)
    builder.removeSelected()
    #expect(builder.layout.center.parts.isEmpty)
}

/// After a refused edit, a reload shows the file's layout and says the edit wasn't saved, even
/// when the file still has the layout last saved.
@MainActor @Test func aReloadAfterARefusalShowsTheFilesLayout() throws {
    let file = try StandIn(center([.art]))
    let builder = try file.builder()
    builder.setStacks(true)
    #expect(builder.layout.center.stacks)
    try builder.reload()
    #expect(!builder.layout.center.stacks)
    #expect(builder.unsaved?.hasPrefix("Not saved: ") == true)
    #expect(builder.unsaved?.contains("art fills the bar's height") == true)
    // Another setting's change reloads again; the note says it once.
    let note = builder.unsaved
    try builder.reload()
    #expect(builder.unsaved == note)
    builder.setAlignment(.leading)
    #expect(builder.unsaved == nil)
}

/// While the config file refuses changes, the builder edits nothing, says why in the banner's
/// words, and turns its controls off.
@MainActor @Test func aBlockedConfigDisablesTheBuilder() throws {
    let file = try StandIn(center([.totals]))
    file.blocked = true
    let window = BarBuilderWindow(model: try file.builder())
    let builder = window.model
    let before = builder.layout
    builder.addColumn(.before)
    builder.place("art", in: .center, at: 0)
    builder.setStacks(true)
    #expect(builder.layout == before)
    try builder.reload()
    #expect(window.message.stringValue.contains(ConfigBanner.blockedText))
    #expect(!window.addBefore.isEnabled)
    file.blocked = false
    try builder.reload()
    #expect(window.addBefore.isEnabled)
}

/// The width field commits when it loses the keys, not only on Return.
@MainActor @Test func theWidthFieldCommitsWhenEditingEnds() throws {
    let file = try StandIn(
        BarLayout(center: BarColumn(parts: [.seek], width: .fixed(200), alignment: .center)))
    let builder = BarBuilderWindow(model: try file.builder())
    let window = builder.window
    defer { window.close() }
    #expect(window.makeFirstResponder(builder.points))
    let editor = try #require(builder.points.currentEditor() as? NSTextView)
    editor.string = "150"
    #expect(window.makeFirstResponder(builder.preview))
    #expect(builder.model.layout.center.width == .fixed(150))
}
