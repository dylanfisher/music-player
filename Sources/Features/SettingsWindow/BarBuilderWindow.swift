import AppKit
import Log
import Settings

private let logger = moduleLogger()

/// The bar builder's window for one `BarLayout` setting, opened from its row in Settings: the
/// preview with its tray, and the controls for the selected column and part. Every control is
/// a standard one, so Tab reaches each, and the preview takes the arrows and Delete.
@MainActor
final class BarBuilderWindow: NSObject {
    static let width = 760.0
    private static let fixedTitle = "Fixed"
    private static let flexibleTitle = "Flexible"

    let window: NSWindow
    let model: BarBuilderModel
    let preview: BarBuilderView
    let addBefore = NSButton()
    private let addAfter = NSButton()
    private let removeColumn = NSButton()
    private let addPart = NSPopUpButton(frame: .zero, pullsDown: true)
    private let removePart = NSButton()
    private let width = NSPopUpButton(frame: .zero, pullsDown: false)
    let points = NSTextField()
    private let alignment = NSSegmentedControl(
        labels: BarAlignment.allCases.map(\.title), trackingMode: .selectOne, target: nil,
        action: nil)
    private let stacks = NSButton(
        checkboxWithTitle: "Stack in Tall Style", target: nil, action: nil)
    let message = NSTextField(wrappingLabelWithString: "")

    init(model: BarBuilderModel) {
        self.model = model
        preview = BarBuilderView(model: model)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 260),
            styleMask: [.titled, .closable], backing: .buffered, defer: true)
        super.init()
        window.title = model.title
        window.isReleasedWhenClosed = false
        build()
        model.changed = { [weak self] in self?.show() }
        show()
    }

    private func build() {
        for (button, title, action) in [
            (addBefore, "Add Column Before", #selector(addColumnBefore)),
            (addAfter, "Add Column After", #selector(addColumnAfter)),
            (removeColumn, "Remove Column", #selector(removeSelectedColumn)),
            (removePart, "Remove Part", #selector(removeSelectedPart)),
        ] {
            button.title = title
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
        }
        addPart.target = self
        addPart.action = #selector(addSelectedPart(_:))
        width.addItems(withTitles: [Self.flexibleTitle, Self.fixedTitle])
        width.target = self
        width.action = #selector(choseWidth)
        width.setAccessibilityLabel("Width")
        points.target = self
        points.action = #selector(typedPoints)
        // Tab or a click elsewhere commits the width, as Return does.
        points.cell?.sendsActionOnEndEditing = true
        points.setAccessibilityLabel("Width in points")
        points.translatesAutoresizingMaskIntoConstraints = false
        points.widthAnchor.constraint(equalToConstant: 60).isActive = true
        alignment.target = self
        alignment.action = #selector(choseAlignment)
        alignment.setAccessibilityLabel("Alignment")
        stacks.target = self
        stacks.action = #selector(toggledStacks)
        message.textColor = .secondaryLabelColor
        message.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        message.preferredMaxLayoutWidth = Self.width - 40

        let columnRow = NSStackView(views: [
            addBefore, addAfter, removeColumn, NSTextField(labelWithString: "Parts:"), addPart,
            removePart,
        ])
        let widthRow = NSStackView(views: [
            NSTextField(labelWithString: "Width:"), width, points,
            NSTextField(labelWithString: "pt"), NSTextField(labelWithString: "Alignment:"),
            alignment, stacks,
        ])
        widthRow.setCustomSpacing(20, after: widthRow.views[3])
        widthRow.setCustomSpacing(20, after: alignment)
        let content = NSStackView(views: [preview, columnRow, widthRow, message])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -40).isActive = true
        window.contentView = content
        window.initialFirstResponder = preview
    }

    func showWindow() {
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
    }

    /// Shows the config file's layout, after a change to the settings.
    func reload() {
        do {
            try model.reload()
        } catch {
            logger.error("\(error)")
            message.stringValue = "\(error)"
        }
    }

    /// Puts the controls in step with the model.
    private func show() {
        preview.invalidateIntrinsicContentSize()
        preview.needsDisplay = true
        let column = model.selectedColumn
        let editable = !model.isBlocked
        removeColumn.isEnabled = editable && model.canRemoveColumn
        removePart.isEnabled = editable && model.selection.part != nil
        for control in [addBefore, addAfter, width, alignment, stacks] as [NSControl] {
            control.isEnabled = editable
        }
        addPart.removeAllItems()
        addPart.addItem(withTitle: "Add Part")
        for part in model.unusedParts {
            addPart.addItem(withTitle: model.title(of: part))
            addPart.lastItem?.representedObject = part
        }
        addPart.isEnabled = editable && !model.unusedParts.isEmpty
        if case .fixed(let fixed) = column?.width {
            width.selectItem(withTitle: Self.fixedTitle)
            points.integerValue = fixed
            points.isEnabled = editable
        } else {
            width.selectItem(withTitle: Self.flexibleTitle)
            points.stringValue = ""
            points.isEnabled = false
        }
        alignment.selectedSegment =
            column.flatMap { BarAlignment.allCases.firstIndex(of: $0.alignment) } ?? -1
        stacks.state = column?.stacks == true ? .on : .off
        let problem =
            editable
            ? model.unsaved : "The config file has a problem. \(ConfigBanner.blockedText)"
        message.stringValue =
            problem
            ?? "Drag parts between columns and the tray. With the preview selected, ← and →"
            + " select, ⌘← and ⌘→ move a part, and Delete removes it. The selected column is"
            + " outlined; the dashed one is centered on the window."
        message.textColor = problem == nil ? .secondaryLabelColor : .systemRed
    }

    @objc private func addColumnBefore() { model.addColumn(.before) }

    @objc private func addColumnAfter() { model.addColumn(.after) }

    @objc private func removeSelectedColumn() { model.removeColumn() }

    @objc private func removeSelectedPart() { model.removeSelected() }

    /// Adds the chosen part at the end of the selected column.
    @objc private func addSelectedPart(_ sender: NSPopUpButton) {
        guard let part = sender.selectedItem?.representedObject as? String else { return }
        model.place(part, in: model.selection.place, at: model.selectedColumn?.parts.count ?? 0)
    }

    @objc private func choseWidth() {
        let fixed = width.titleOfSelectedItem == Self.fixedTitle
        // A column made fixed starts at its width in the preview.
        let start = preview.columnFrames[model.selection.place].map { Int($0.width.rounded()) }
        model.setWidth(
            fixed
                ? .fixed(
                    min(
                        max(start ?? 100, BarWidth.fixedRangePoints.lowerBound),
                        BarWidth.fixedRangePoints.upperBound)) : .flexible)
    }

    @objc private func typedPoints() {
        guard let typed = Int(points.stringValue.trimmingCharacters(in: .whitespaces)) else {
            message.stringValue =
                "The width needs a whole number of points, not \"\(points.stringValue)\""
            message.textColor = .systemRed
            return
        }
        model.setWidth(.fixed(typed))
    }

    @objc private func choseAlignment() {
        guard BarAlignment.allCases.indices.contains(alignment.selectedSegment) else { return }
        model.setAlignment(BarAlignment.allCases[alignment.selectedSegment])
    }

    @objc private func toggledStacks() { model.setStacks(stacks.state == .on) }
}
