import Foundation
import Settings

/// The bar builder's state for one `BarLayout` setting: the layout shown, the part or column
/// selected, and the edits the builder's drags, buttons and keys make (ADR 0085). It holds the
/// parts by their names in the config file, so one builder serves every bar. Each edit saves
/// the layout as a patch to its own key, except while a column is empty: a column added for a
/// part to be dragged into is shown, and saved once it has one.
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
    private(set) var layout: BarLayout<String>
    private(set) var selection = Selection(place: .center)
    /// Why the layout shown isn't the one in effect, or nil when it is.
    private(set) var unsaved: String?
    /// Called after every change to the layout or the selection.
    var changed: () -> Void = {}
    /// The layout as the config file last had it.
    private var saved: BarLayout<String>
    private let value: () -> Any?
    private let set: (Any) throws -> Void

    /// `value` reads the setting as JSON holds it; `set` writes it.
    init(
        key: String, title: String, choices: [SettingKind.Choice], value: @escaping () -> Any?,
        set: @escaping (Any) throws -> Void
    ) throws {
        self.key = key
        self.title = title
        self.choices = choices
        self.value = value
        self.set = set
        saved = try Self.read(key, value())
        layout = saved
    }

    private static func read(_ key: String, _ json: Any?) throws -> BarLayout<String> {
        guard let json else { throw ConfigProblem(line: nil, message: "\(key) has no value") }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(BarLayout<String>.self, from: data)
    }

    /// Shows the layout the config file has now, unless it's the one this builder last saved,
    /// so a column waiting for a part survives another setting's change.
    func reload() throws {
        let current = try Self.read(key, value())
        guard current != saved else { return }
        saved = current
        layout = current
        unsaved = nil
        if layout[selection.place] == nil { selection = Selection(place: .center) }
        changed()
    }

    func title(of part: String) -> String { choices.first { $0.rawValue == part }?.title ?? part }

    /// The parts no column holds, in the bar's order of choices.
    var unusedParts: [String] {
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
        switch place {
        case .leading(let index): layout.leading.insert(column, at: index)
        case .trailing(let index): layout.trailing.insert(column, at: index)
        case .center: preconditionFailure("the center column is never added")
        }
        selection = Selection(place: place)
        save()
    }

    /// Whether the selected column can go: any but the center.
    var canRemoveColumn: Bool { selection.place != .center }

    /// Removes the selected column; its parts go back to the unused ones.
    func removeColumn() {
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
        save()
    }

    func setWidth(_ width: BarWidth) { editColumn { $0.width = width } }

    func setAlignment(_ alignment: BarAlignment) { editColumn { $0.alignment = alignment } }

    func setStacks(_ stacks: Bool) { editColumn { $0.stacks = stacks } }

    private func editColumn(_ edit: (inout BarColumn<String>) -> Void) {
        update(selection.place, edit)
        save()
    }

    private func update(_ place: BarPlace, _ edit: (inout BarColumn<String>) -> Void) {
        switch place {
        case .leading(let index): edit(&layout.leading[index])
        case .center: edit(&layout.center)
        case .trailing(let index): edit(&layout.trailing[index])
        }
    }

    // MARK: Parts

    func select(_ selection: Selection) {
        guard let column = layout[selection.place],
            selection.part.map(column.parts.indices.contains) != false
        else { return }
        self.selection = selection
        changed()
    }

    /// Puts `part` at `index` in the column at `place`, from wherever it was, an unused part
    /// included, and selects it there.
    func place(_ part: String, in place: BarPlace, at index: Int) {
        guard choices.contains(where: { $0.rawValue == part }), layout[place] != nil else { return }
        var target = index
        if let from = location(of: part) {
            if from.place == place, from.index < index { target -= 1 }
            update(from.place) { $0.parts.remove(at: from.index) }
        }
        update(place) { column in
            target = min(max(target, 0), column.parts.count)
            column.parts.insert(part, at: target)
        }
        selection = Selection(place: place, part: target)
        save()
    }

    /// Takes `part` out of its column, back to the unused ones.
    func remove(_ part: String) {
        guard let from = location(of: part) else { return }
        update(from.place) { $0.parts.remove(at: from.index) }
        let left = layout[from.place]?.parts.count ?? 0
        selection = Selection(place: from.place, part: left == 0 ? nil : min(from.index, left - 1))
        save()
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
            return place(part, in: selection.place, at: forward ? next + 1 : next)
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

    /// Saves the layout unless a column is empty; a refusal leaves the layout shown, with why.
    private func save() {
        if let empty = layout.columns.first(where: { $0.column.parts.isEmpty }) {
            unsaved = "Drag a part into \(empty.place) to save the layout."
        } else if layout == saved {
            unsaved = nil
        } else {
            do {
                let data = try JSONEncoder().encode(layout)
                try set(try JSONSerialization.jsonObject(with: data))
                saved = layout
                unsaved = nil
            } catch {
                unsaved = "\(error)"
            }
        }
        changed()
    }
}
