import AppKit
import Foundation
import Testing

@testable import Settings
@testable import SettingsWindow

/// A builder over a dictionary standing in for the config file, which takes only layouts the
/// real setting accepts, and the dictionary.
@MainActor
private func builder(_ layout: BarLayout<StatusPart> = .defaultStatusBar) throws -> (
    BarBuilderModel, () -> [String: Any]
) {
    let setting = AppSettings().statusBarLayout
    nonisolated(unsafe) var values: [String: Any] = [
        setting.key: try JSONSerialization.jsonObject(with: JSONEncoder().encode(layout))
    ]
    let model = GeneralModel(
        settings: [setting.descriptor], searcherInstalled: true, value: { values[$0] },
        set: { key, json in
            if case .failure(let reason) = setting.decode(json: json) {
                throw SettingProblem(key: key, reason: reason)
            }
            values[key] = json
        }, isBlocked: { false })
    return (try model.barBuilder(setting.key), { values })
}

/// The layout the config file holds.
private func saved(_ values: [String: Any]) throws -> BarLayout<StatusPart> {
    let json = try #require(values[AppSettings().statusBarLayout.key])
    return try JSONDecoder().decode(
        BarLayout<StatusPart>.self, from: JSONSerialization.data(withJSONObject: json))
}

@MainActor @Test func theAppearanceRowOpensTheBuilderOnTheStatusBarsParts() throws {
    let (builder, _) = try builder()
    #expect(builder.title == AppSettings().statusBarLayout.title)
    #expect(builder.choices.map(\.rawValue) == StatusPart.allCases.map(\.rawValue))
    #expect(builder.layout.center.parts == ["totals"])
    #expect(builder.unusedParts == ["art", "track", "format", "seek"])
}

/// Each edit saves as it's made, a new column while it's still empty.
@MainActor @Test func columnsAreAddedBesideTheSelectionAndSaveAtOnce() throws {
    let (builder, values) = try builder()
    builder.addColumn(.before)
    #expect(builder.selection == .init(place: .leading(0)))
    #expect(builder.layout.leading.first?.alignment == .leading)
    #expect(builder.unsaved == nil)
    #expect(try saved(values()).leading.map(\.parts) == [[]])

    builder.place("art", in: .leading(0), at: 0)
    #expect(builder.unsaved == nil)
    #expect(try saved(values()).leading.map(\.parts) == [[.art]])

    builder.select(.init(place: .center))
    builder.addColumn(.after)
    builder.place("seek", in: .trailing(0), at: 0)
    builder.addColumn(.before)
    #expect(builder.selection.place == .trailing(0))
    builder.place("format", in: .trailing(0), at: 0)
    builder.setWidth(.fixed(120))
    builder.setAlignment(.center)
    let layout = try saved(values())
    #expect(layout.trailing.map(\.parts) == [[.format], [.seek]])
    #expect(layout.trailing[0].width == .fixed(120))
    #expect(layout.trailing[0].alignment == .center)

    builder.removeColumn()
    #expect(try saved(values()).trailing.map(\.parts) == [[.seek]])
    #expect(builder.unusedParts.contains("format"))
    builder.select(.init(place: .center))
    #expect(!builder.canRemoveColumn)
}

/// An edit that would give the layout a problem is refused: the layout stays as it was, and the
/// hint line says why in plain words, without the config file's path or the setting's key.
@MainActor @Test func anEditThatWouldMakeAProblemIsRefused() throws {
    let (builder, values) = try builder()
    builder.place("art", in: .center, at: 0)
    builder.setStacks(true)
    #expect(
        builder.refused
            == "Art is as tall as the bar, so it can't stack with other parts in the center column."
    )
    #expect(!builder.layout.center.stacks)
    #expect(builder.unsaved == nil)
    #expect(try saved(values()).center.stacks == false)
    builder.setWidth(.fixed(2))
    #expect(builder.refused?.hasPrefix("The center column is 2 points wide") == true)
    #expect(builder.layout.center.width == .flexible)
    builder.select(.init(place: .center))
    #expect(builder.refused == nil, "the next step clears it")

    // Alone, the art stacks.
    builder.remove("totals")
    builder.setStacks(true)
    #expect(builder.refused == nil)
    #expect(
        try saved(values()).center
            == BarColumn(
                parts: [.art], width: .flexible, alignment: .center, stacks: true))
}

@MainActor @Test func theHintLineSaysWhyAnEditWasRefused() throws {
    let (builder, _) = try builder()
    let window = BarBuilderWindow(model: builder)
    builder.setWidth(.fixed(2))
    let refused = try #require(builder.refused)
    #expect(window.message.stringValue == refused)
    #expect(!refused.contains(AppSettings().statusBarLayout.key))
}

/// The keys walk the parts left to right, move one across columns, and take one out.
@MainActor @Test func theKeysSelectMoveAndRemoveParts() throws {
    let (builder, values) = try builder(
        BarLayout(
            leading: [BarColumn(parts: [.art, .track], width: .flexible, alignment: .leading)],
            center: BarColumn(parts: [.seek], width: .flexible, alignment: .center)))
    builder.select(.init(place: .leading(0), part: 0))
    builder.selectNext(true)
    #expect(builder.selection == .init(place: .leading(0), part: 1))
    builder.selectNext(true)
    #expect(builder.selection == .init(place: .center, part: 0))
    builder.selectNext(true)
    #expect(builder.selection == .init(place: .center, part: 0), "nothing after the last")

    builder.select(.init(place: .leading(0), part: 0))
    builder.moveSelected(true)
    #expect(builder.layout.leading[0].parts == ["track", "art"])
    #expect(builder.selection == .init(place: .leading(0), part: 1))
    builder.moveSelected(true)
    #expect(builder.layout.leading[0].parts == ["track"])
    #expect(builder.layout.center.parts == ["art", "seek"])
    #expect(builder.selection == .init(place: .center, part: 0))
    builder.moveSelected(false)
    #expect(builder.layout.leading[0].parts == ["track", "art"])
    builder.removeSelected()
    #expect(builder.layout.leading[0].parts == ["track"])
    #expect(builder.selection == .init(place: .leading(0), part: 0))
    #expect(try saved(values()).leading[0].parts == [.track])
}

/// A change made elsewhere shows, replacing a column just added.
@MainActor @Test func aReloadShowsTheConfigsLayout() throws {
    let setting = AppSettings().statusBarLayout
    nonisolated(unsafe) var values: [String: Any] = [
        setting.key: try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(BarLayout<StatusPart>.defaultStatusBar))
    ]
    let model = GeneralModel(
        settings: [setting.descriptor], searcherInstalled: true, value: { values[$0] },
        set: { key, json in values[key] = json }, isBlocked: { false })
    let builder = try model.barBuilder(setting.key)
    builder.addColumn(.before)
    try builder.reload()
    #expect(builder.layout.leading.count == 1, "the empty column was saved")
    values[setting.key] = try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(
            BarLayout<StatusPart>(
                center: BarColumn(parts: [.seek], width: .flexible, alignment: .center))))
    try builder.reload()
    #expect(builder.layout.leading.isEmpty)
    #expect(builder.layout.center.parts == ["seek"])
    #expect(builder.unsaved == nil)
}

@Test func thePreviewCentersTheCenterColumnAndSharesTheRest() {
    let preview = BarPreview(spacing: 10, inset: 10)
    let layout = BarLayout<String>(
        leading: [BarColumn(parts: ["art"], width: .fixed(100), alignment: .leading)],
        center: BarColumn(parts: ["seek"], width: .flexible, alignment: .center),
        trailing: [BarColumn(parts: ["format"], width: .flexible, alignment: .trailing)])
    let spans = preview.columns(of: layout, width: 1000) { _ in 50 }
    #expect(spans[.leading(0)]?.x == 10 && spans[.leading(0)]?.width == 100)
    let center = try! #require(spans[.center])
    #expect(center.x + center.width / 2 == 500)
    let trailing = try! #require(spans[.trailing(0)])
    #expect(trailing.x + trailing.width == 990)
    #expect(trailing.x == center.x + center.width + 10, "the trailing column reaches the center")

    // A center too wide to stay centered moves aside rather than overlap.
    let wide = BarLayout<String>(
        leading: [BarColumn(parts: ["art"], width: .fixed(400), alignment: .leading)],
        center: BarColumn(parts: ["seek"], width: .fixed(300), alignment: .center))
    #expect(preview.columns(of: wide, width: 1000) { _ in 50 }[.center]?.x == 420)
}

/// A drag let go over a column puts the part before the chip past the pointer, and one let go
/// over the tray takes it out of the bar.
@MainActor @Test func aDropPlacesThePartWhereItLetGo() throws {
    let (builder, values) = try builder(
        BarLayout(center: BarColumn(parts: [.track, .seek], width: .flexible, alignment: .center)))
    let view = BarBuilderView(model: builder)
    view.frame = NSRect(x: 0, y: 0, width: 760, height: view.intrinsicContentSize.height)
    let chips = view.chips
    let seek = try #require(chips.first { $0.part == "seek" })
    let track = try #require(chips.first { $0.part == "track" })
    view.drop("seek", at: NSPoint(x: track.frame.minX + 1, y: track.frame.midY))
    #expect(builder.layout.center.parts == ["seek", "track"])
    let art = try #require(chips.first { $0.part == "art" })
    #expect(art.place == nil, "art starts in the tray")
    view.drop("art", at: NSPoint(x: seek.frame.maxX + 40, y: seek.frame.midY))
    #expect(builder.layout.center.parts == ["seek", "track", "art"])
    view.drop("track", at: NSPoint(x: 5, y: view.trayFrame.midY))
    #expect(try saved(values()).center.parts == [.seek, .art])
}

/// Reset to Default saves the setting's default through the builder's own patch, and is off
/// while the layout is the default.
@MainActor @Test func resetToDefaultSavesTheDefault() throws {
    let (builder, values) = try builder(
        BarLayout(
            leading: [BarColumn(parts: [.art], width: .fixed(40), alignment: .leading)],
            center: BarColumn(parts: [.seek], width: .flexible, alignment: .center)))
    let window = BarBuilderWindow(model: builder)
    #expect(window.reset.isEnabled)
    builder.select(.init(place: .leading(0), part: 0))
    builder.resetToDefault()
    #expect(try saved(values()) == .defaultStatusBar)
    #expect(builder.layout.center.parts == ["totals"])
    #expect(builder.selection == .init(place: .center))
    #expect(!window.reset.isEnabled)
}
