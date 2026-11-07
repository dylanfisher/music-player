import AppKit
import DisplayText
import Library

/// The smart playlist editor: a sheet with the name, "Match all/any of these rules", a row of
/// pop-up buttons and a field per rule with − and + beside it, and the limit. It edits a
/// `RuleDraft` and hands back the name and rules once they're valid.
@MainActor
public final class RuleEditorSheet: NSObject, NSTextFieldDelegate {
    public private(set) var draft: RuleDraft
    public let window: NSWindow
    /// Called with the name and rules when the user saves; the sheet has closed.
    public var saved: (String, SmartRules) -> Void = { _, _ in }

    private let nameField = NSTextField()
    private let matchButton = NSPopUpButton()
    private let rowsStack = NSStackView()
    private let limitBox = NSButton(checkboxWithTitle: "Limit to", target: nil, action: nil)
    private let limitField = NSTextField()
    private let orderButton = NSPopUpButton()
    private let problemLabel = NSTextField(labelWithString: "")
    private let saveButton: NSButton
    /// The value fields, by row, to read typing from.
    private var valueFields: [NSTextField] = []

    /// The sheet's width, which fits a rule row with its longest field and comparison titles.
    static let width = 640.0

    /// `saveTitle` names what saving does: "Create" for a new playlist, "Save" for an edit.
    public init(draft: RuleDraft, saveTitle: String) {
        self.draft = draft
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 240),
            styleMask: [.titled], backing: .buffered, defer: false)
        saveButton = NSButton(title: saveTitle, target: nil, action: nil)
        super.init()
        window.contentView = makeContent()
        showRows()
    }

    /// Opens over `parent`.
    public func begin(over parent: NSWindow) {
        parent.beginSheet(window)
        window.makeFirstResponder(nameField)
    }

    private func makeContent() -> NSView {
        nameField.stringValue = draft.name
        nameField.placeholderString = "Playlist name"
        nameField.delegate = self
        let nameRow = NSStackView(views: [NSTextField(labelWithString: "Name:"), nameField])

        for match in SmartRules.Match.allCases { matchButton.addItem(withTitle: match.title) }
        matchButton.selectItem(at: SmartRules.Match.allCases.firstIndex(of: draft.match) ?? 0)
        matchButton.target = self
        matchButton.action = #selector(matchChanged)
        let matchRow = NSStackView(views: [
            NSTextField(labelWithString: "Match"), matchButton,
            NSTextField(labelWithString: "of these rules:"),
        ])

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 6

        limitBox.target = self
        limitBox.action = #selector(limitChanged)
        limitBox.state = draft.isLimited ? .on : .off
        limitField.stringValue = draft.limitCount
        limitField.delegate = self
        limitField.alignment = .right
        limitField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        for order in SmartOrder.allCases { orderButton.addItem(withTitle: order.title) }
        orderButton.selectItem(at: SmartOrder.allCases.firstIndex(of: draft.limitOrder) ?? 0)
        orderButton.target = self
        orderButton.action = #selector(orderChanged)
        let limitRow = NSStackView(views: [
            limitBox, limitField, NSTextField(labelWithString: "tracks, picked by"), orderButton,
        ])
        showLimit()

        problemLabel.textColor = .systemRed
        problemLabel.lineBreakMode = .byWordWrapping
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        saveButton.target = self
        saveButton.action = #selector(saveClicked)
        saveButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [problemLabel, cancel, saveButton])
        problemLabel.setContentHuggingPriority(.init(1), for: .horizontal)
        problemLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [nameRow, matchRow, rowsStack, limitRow, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(
            top: DialogMargin.value, left: DialogMargin.value, bottom: DialogMargin.value,
            right: DialogMargin.value)
        for view in [nameRow, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(
                equalTo: stack.widthAnchor, constant: -2 * DialogMargin.value
            ).isActive = true
        }
        stack.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        return stack
    }

    /// Builds a line per rule from the draft.
    private func showRows() {
        for view in rowsStack.arrangedSubviews { view.removeFromSuperview() }
        valueFields = []
        for (index, row) in draft.rows.enumerated() {
            let field = NSPopUpButton()
            for each in SmartField.allCases { field.addItem(withTitle: each.title) }
            field.selectItem(at: SmartField.allCases.firstIndex(of: row.field) ?? 0)
            field.tag = index
            field.target = self
            field.action = #selector(fieldChanged(_:))

            let comparisons = SmartComparison.comparisons(for: row.field.kind)
            let comparison = NSPopUpButton()
            for each in comparisons { comparison.addItem(withTitle: each.title) }
            comparison.selectItem(at: comparisons.firstIndex(of: row.comparison) ?? 0)
            comparison.tag = index
            comparison.target = self
            comparison.action = #selector(comparisonChanged(_:))

            let value = NSTextField()
            value.stringValue = row.value
            value.tag = index
            value.delegate = self
            value.widthAnchor.constraint(equalToConstant: 180).isActive = true
            valueFields.append(value)

            let unit = NSTextField(labelWithString: row.field.unit ?? "")
            unit.textColor = .secondaryLabelColor
            unit.widthAnchor.constraint(equalToConstant: 50).isActive = true

            let remove = NSButton(title: "−", target: self, action: #selector(removeClicked(_:)))
            remove.tag = index
            remove.bezelStyle = .circular
            remove.isEnabled = draft.rows.count > 1
            remove.toolTip = "Remove this rule"
            let add = NSButton(title: "+", target: self, action: #selector(addClicked(_:)))
            add.tag = index
            add.bezelStyle = .circular
            add.toolTip = "Add a rule after this one"
            rowsStack.addArrangedSubview(
                NSStackView(views: [field, comparison, value, unit, remove, add]))
        }
        // The sheet grows and shrinks with its rules.
        if let content = window.contentView { window.setContentSize(content.fittingSize) }
    }

    private func showLimit() {
        limitField.isEnabled = draft.isLimited
        orderButton.isEnabled = draft.isLimited
    }

    @objc private func matchChanged() {
        draft.match = SmartRules.Match.allCases[matchButton.indexOfSelectedItem]
    }

    @objc private func limitChanged() {
        draft.isLimited = limitBox.state == .on
        showLimit()
    }

    @objc private func orderChanged() {
        draft.limitOrder = SmartOrder.allCases[orderButton.indexOfSelectedItem]
    }

    @objc private func fieldChanged(_ sender: NSPopUpButton) {
        draft.setField(SmartField.allCases[sender.indexOfSelectedItem], at: sender.tag)
        showRows()
    }

    @objc private func comparisonChanged(_ sender: NSPopUpButton) {
        let comparisons = SmartComparison.comparisons(for: draft.rows[sender.tag].field.kind)
        draft.setComparison(comparisons[sender.indexOfSelectedItem], at: sender.tag)
    }

    @objc private func addClicked(_ sender: NSButton) {
        draft.addRow(after: sender.tag)
        showRows()
    }

    @objc private func removeClicked(_ sender: NSButton) {
        draft.removeRow(at: sender.tag)
        showRows()
    }

    public func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === nameField {
            draft.name = field.stringValue
        } else if field === limitField {
            draft.limitCount = field.stringValue
        } else if valueFields.indices.contains(field.tag), valueFields[field.tag] === field {
            draft.setValue(field.stringValue, at: field.tag)
        }
    }

    @objc private func cancelClicked() { close() }

    @objc private func saveClicked() {
        do {
            let name = try draft.checkedName()
            let rules = try draft.rules()
            close()
            saved(name, rules)
        } catch {
            problemLabel.stringValue = error.description
            NSSound.beep()
        }
    }

    private func close() {
        window.sheetParent?.endSheet(window)
        window.orderOut(nil)
    }
}
