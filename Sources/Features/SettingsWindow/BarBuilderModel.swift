import Foundation
import Settings

/// The bar builder's state for one `BarLayout` setting: the layout shown, the part or column
/// selected, and the edits the builder's drags, buttons and keys make (ADR 0085). It holds the
/// parts by their names in the config file, so one builder serves every bar. Each edit saves
/// the layout as a patch to its own key.
@MainActor
final class BarBuilderModel {
    /// A column, and a part in it when one is selected.
    struct Selection: Equatable {
        var place: BarPlace
        var part: Int?
    }

    /// Which side of the selected column a new column goes.
    enum Side {
        case before, after
    }

    let key: String
    let title: String
    let choices: [SettingKind.Choice]
    /// The words and the height that differ between bars.
    let bar: SettingKind.Bar
    /// The setting's default, which Reset to Default puts back.
    let defaultLayout: BarLayout<String>
    private(set) var layout: BarLayout<String>
    private(set) var selection = Selection(place: .center)
    /// Why the layout shown isn't the one in effect, or nil when it is.
    private(set) var unsaved: String?
    /// Why the last edit was refused, which would have given the layout a problem; the layout
    /// shown is the one before it.
    private(set) var refused: String?
    /// Why the last save was refused, kept apart from `unsaved`'s wording, so a reload says it
    /// once however many reloads follow.
    private var refusal: String?
    /// Called after every change to the layout or the selection.
    var changed: () -> Void = {}
    /// The layout as the config file last had it.
    private var saved: BarLayout<String>
    private let value: () -> Any?
    private let set: (Any) throws -> Void
    private let blocked: () -> Bool

    /// `value` reads the setting as JSON holds it; `set` writes it. `blocked` says whether the
    /// config file has a problem that refuses every change until it's fixed.
    init(
        key: String, title: String, bar: SettingKind.Bar, defaultLayout: BarLayout<String>,
        value: @escaping () -> Any?,
        set: @escaping (Any) throws -> Void, blocked: @escaping () -> Bool
    ) throws {
        self.key = key
        self.title = title
        self.choices = bar.choices
        self.bar = bar
        self.defaultLayout = defaultLayout
        self.value = value
        self.set = set
        self.blocked = blocked
        saved = try Self.read(key, value())
        layout = saved
    }

    private static func read(_ key: String, _ json: Any?) throws -> BarLayout<String> {
        guard let json else { throw ConfigProblem(line: nil, message: "\(key) has no value") }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(BarLayout<String>.self, from: data)
    }

    /// Whether the config file refuses every change until it's fixed; the builder edits
    /// nothing meanwhile.
    var isBlocked: Bool { blocked() }

    /// Shows the layout the config file has now. A refused save gives way to the file's
    /// layout, saying it wasn't saved.
    func reload() throws {
        saved = try Self.read(key, value())
        layout = saved
        unsaved = refusal.map { "Not saved: \($0)" }
        keepSelectionInLayout()
        changed()
    }

    /// Moves the selection to what the layout still has: the last part of a column that lost
    /// parts, or the center column for one that's gone.
    private func keepSelectionInLayout() {
        guard let column = layout[selection.place] else {
            selection = Selection(place: .center)
            return
        }
        if let part = selection.part, part >= column.parts.count {
            selection.part = column.parts.isEmpty ? nil : column.parts.count - 1
        }
    }

    func title(of part: String) -> String { choices.first { $0.rawValue == part }?.title ?? part }

    /// The parts no column holds, in the bar's order of choices.
    var unusedParts: [String] { unusedParts(in: layout) }

    /// The parts no column of `layout` holds, in the bar's order of choices.
    func unusedParts(in layout: BarLayout<String>) -> [String] {
        let used = Set(layout.columns.flatMap(\.column.parts))
        return choices.map(\.rawValue).filter { !used.contains($0) }
    }

    var selectedColumn: BarColumn<String>? { layout[selection.place] }

    // MARK: Columns

    /// Adds an empty flexible column beside the selected one and selects it. The center column
    /// stays the only one, so a column beside it goes to that side's list.
    func addColumn(_ side: Side) {
        let place: BarPlace
        switch (selection.place, side) {
        case (.center, .before): place = .leading(layout.leading.count)
        case (.center, .after): place = .trailing(0)
        case (.leading(let index), _): place = .leading(side == .before ? index : index + 1)
        case (.trailing(let index), _): place = .trailing(side == .before ? index : index + 1)
        }
        let alignment: BarAlignment = if case .leading = place { .leading } else { .trailing }
        let column = BarColumn<String>(parts: [], width: .flexible, alignment: alignment)
        edit {
            switch place {
            case .leading(let index): layout.leading.insert(column, at: index)
            case .trailing(let index): layout.trailing.insert(column, at: index)
            case .center: preconditionFailure("the center column is never added")
            }
            selection = Selection(place: place)
        }
    }

    /// Whether the selected column can go: any but the center.
    var canRemoveColumn: Bool { selection.place != .center }

    /// Removes the selected column; its parts go back to the unused ones.
    func removeColumn() {
        guard canRemoveColumn else { return }
        edit {
            switch selection.place {
            case .center: return
            case .leading(let index):
                layout.leading.remove(at: index)
                selection.place = index > 0 ? .leading(index - 1) : .center
            case .trailing(let index):
                layout.trailing.remove(at: index)
                selection.place = index > 0 ? .trailing(index - 1) : .center
            }
            selection.part = nil
        }
    }

    /// Moves the side column at `place` to `target`, its place among the side columns once
    /// it's out of its own, and selects it there. The center column stays where it is.
    func moveColumn(_ place: BarPlace, to target: BarPlace) {
        guard place != .center, target != .center else { return }
        edit {
            layout = moving(place, to: target)
            selection = Selection(place: target)
        }
    }

    /// The layout as `moveColumn(_:to:)` would make it, which a drag shows before the drop.
    func moving(_ place: BarPlace, to target: BarPlace) -> BarLayout<String> {
        var layout = layout
        let column: BarColumn<String>
        switch place {
        case .center: return layout
        case .leading(let index): column = layout.leading.remove(at: index)
        case .trailing(let index): column = layout.trailing.remove(at: index)
        }
        switch target {
        case .center: return self.layout
        case .leading(let index):
            layout.leading.insert(column, at: min(max(index, 0), layout.leading.count))
        case .trailing(let index):
            layout.trailing.insert(column, at: min(max(index, 0), layout.trailing.count))
        }
        return layout
    }

    func setWidth(_ width: BarWidth) { editColumn { $0.width = width } }

    func setAlignment(_ alignment: BarAlignment) { editColumn { $0.alignment = alignment } }

    func setStacks(_ stacks: Bool) { editColumn { $0.stacks = stacks } }

    private func editColumn(_ change: (inout BarColumn<String>) -> Void) {
        edit { layout.update(selection.place, change) }
    }

    /// Whether the layout is the setting's default, which Reset to Default would leave as it is.
    var isDefault: Bool { layout == defaultLayout }

    /// Puts the setting's default back, saving it as any edit is.
    func resetToDefault() {
        edit {
            layout = defaultLayout
            selection = Selection(place: .center)
        }
    }

    // MARK: Parts

    func select(_ selection: Selection) {
        guard let column = layout[selection.place],
            selection.part.map(column.parts.indices.contains) != false
        else { return }
        self.selection = selection
        refused = nil
        changed()
    }

    /// Puts `part` at `index` among the other parts of the column at `place`, from wherever it
    /// was, an unused part included, and selects it there.
    func place(_ part: String, in place: BarPlace, at index: Int) {
        guard choices.contains(where: { $0.rawValue == part }), layout[place] != nil else { return }
        edit {
            layout = placing(part, in: place, at: index)
            selection = Selection(place: place, part: layout[place]?.parts.firstIndex(of: part))
        }
    }

    /// The layout as `place(_:in:at:)` would make it, which a drag shows before the drop.
    func placing(_ part: String, in place: BarPlace, at index: Int) -> BarLayout<String> {
        var layout = removing(part)
        layout.update(place) { $0.parts.insert(part, at: min(max(index, 0), $0.parts.count)) }
        return layout
    }

    /// The layout with `part` out of whichever column holds it.
    func removing(_ part: String) -> BarLayout<String> {
        var layout = layout
        if let from = location(of: part) {
            layout.update(from.place) { $0.parts.remove(at: from.index) }
        }
        return layout
    }

    /// Takes `part` out of its column, back to the unused ones.
    func remove(_ part: String) {
        guard let from = location(of: part) else { return }
        edit {
            layout = removing(part)
            let left = layout[from.place]?.parts.count ?? 0
            selection = Selection(
                place: from.place, part: left == 0 ? nil : min(from.index, left - 1))
        }
    }

    private func location(of part: String) -> (place: BarPlace, index: Int)? {
        for (place, column) in layout.columns {
            if let index = column.parts.firstIndex(of: part) { return (place, index) }
        }
        return nil
    }

    // MARK: Keys

    /// Every stop the arrow keys select, left to right: each part, and each empty column.
    private var stops: [Selection] {
        layout.columns.flatMap { place, column in
            column.parts.isEmpty
                ? [Selection(place: place)]
                : column.parts.indices.map { Selection(place: place, part: $0) }
        }
    }

    /// The selected part's or column's place among the stops.
    private var stop: Int {
        let stops = stops
        return stops.firstIndex(of: selection)
            ?? stops.firstIndex { $0.place == selection.place } ?? 0
    }

    /// Selects the part or empty column after the selection, or before it.
    func selectNext(_ forward: Bool) {
        let stops = stops
        let next = stop + (forward ? 1 : -1)
        guard stops.indices.contains(next) else { return }
        selection = stops[next]
        changed()
    }

    /// Moves the selected part one place right, or left, into the next column at its edge.
    func moveSelected(_ forward: Bool) {
        guard let index = selection.part, let column = selectedColumn else { return }
        let part = column.parts[index]
        let next = index + (forward ? 1 : -1)
        if column.parts.indices.contains(next) {
            return place(part, in: selection.place, at: next)
        }
        let places = layout.columns.map(\.place)
        guard let here = places.firstIndex(of: selection.place),
            places.indices.contains(here + (forward ? 1 : -1))
        else { return }
        let neighbor = places[here + (forward ? 1 : -1)]
        place(part, in: neighbor, at: forward ? 0 : layout[neighbor]?.parts.count ?? 0)
    }

    func removeSelected() {
        guard let index = selection.part, let part = selectedColumn?.parts[index] else { return }
        remove(part)
    }

    // MARK: Saving

    /// Makes `change` to the layout and the selection and saves it, or refuses it, putting both
    /// back and saying why, when the layout would have a problem.
    private func edit(_ change: () -> Void) {
        guard !isBlocked else { return }
        let before = (layout, selection)
        change()
        if let problem = problem(in: layout) {
            (layout, selection) = before
            refused = problem
            return changed()
        }
        refused = nil
        save()
    }

    /// The first thing wrong with `layout`, as a sentence, or nil when it can be saved.
    func problem(in layout: BarLayout<String>) -> String? {
        let problems = layout.problems(
            fillsHeight: bar.fillsHeight.contains, title: title(of:))
        return problems.first.map { problem in
            let text = "\(problem)"
            return text.prefix(1).uppercased() + text.dropFirst() + "."
        }
    }

    /// Saves the layout; a refusal leaves the layout shown, with why.
    private func save() {
        refusal = nil
        if layout == saved {
            unsaved = nil
        } else {
            do {
                let data = try JSONEncoder().encode(layout)
                try set(try JSONSerialization.jsonObject(with: data))
                saved = layout
                unsaved = nil
            } catch {
                refusal = "\(error)"
                unsaved = refusal
            }
        }
        changed()
    }
}

extension BarLayout<String> {
    /// Changes the column at `place`.
    fileprivate mutating func update(_ place: BarPlace, _ edit: (inout BarColumn<String>) -> Void) {
        switch place {
        case .leading(let index): edit(&leading[index])
        case .center: edit(&center)
        case .trailing(let index): edit(&trailing[index])
        }
    }
}
