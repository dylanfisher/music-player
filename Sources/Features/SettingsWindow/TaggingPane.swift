import AppKit
import Discogs
import Log
import Metadata
import Settings

private let logger = moduleLogger()

/// Settings ▸ Tagging (ADR 0165): the Discogs tagger's field mapping in use, a table of each
/// field, by its title with its key in the config file as the tooltip, and its rule; under it the selected field's rule, with
/// its tags spelled per format and how its value is written. The problem the config file would
/// find shows under the rule as it's edited, and Save writes the mapping; Revert puts the
/// file's back.
@MainActor
final class TaggingPane: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
    NSTextFieldDelegate
{
    static let summary =
        "The Discogs tagger's field mapping in use, as config.json holds it under"
        + " “\(TaggingModel.setting.key)”: each field and its rule. The tagger's Field Mapping"
        + " sheet edits the same mapping, and saves and chooses named ones."
    static let fieldTitle = "Field"

    /// A field's tooltip in the table: its key in the config file.
    static func keyTip(_ field: DiscogsField) -> String {
        "“\(field.rawValue)” in config.json"
    }
    static let ruleTitle = "Rule"
    static let numberedTitle = "Numbered Keys"
    private static let fieldsHeight = 200.0
    private static let tagsHeight = 96.0
    private static let controlWidth = 420.0

    let model: TaggingModel
    let fieldsTable = NSTableView()
    let tagsTable = NSTableView()
    let modePopUp = NSPopUpButton()
    let joinField = NSTextField()
    let templateField = NSTextField()
    /// The format parts' pop-ups, in `TaggingModel.Part.all`'s order, each tagged with its
    /// place there.
    private(set) var partPopUps: [NSPopUpButton] = []
    let addTagButton = NSButton()
    let removeTagButton = NSButton()
    let ruleHeading = NSTextField(labelWithString: "")
    let problemLabel = NSTextField(wrappingLabelWithString: "")
    let noteLabel = NSTextField(wrappingLabelWithString: "")
    let revertButton = NSButton(title: "Revert", target: nil, action: nil)
    /// The field whose tags the tags table lists, which an edit in one of its cells is to,
    /// even once another field is selected.
    private var tagsField = TaggingModel.fields[0]
    let saveButton = NSButton(title: "Save", target: nil, action: nil)

    /// The pop-up of the format part `part`.
    func popUp(_ part: TaggingModel.Part) -> NSPopUpButton {
        partPopUps[TaggingModel.Part.all.firstIndex(of: part)!]
    }

    init(model: TaggingModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    /// The field whose rule the form shows: the selected row's, or the first.
    var field: DiscogsField {
        TaggingModel.fields[max(fieldsTable.selectedRow, 0)]
    }

    override func loadView() {
        let summary = NSTextField(wrappingLabelWithString: Self.summary)
        summary.textColor = .secondaryLabelColor
        let fields = scroll(
            fieldsTable, columns: [(Self.fieldTitle, 150), (Self.ruleTitle, 420)],
            height: Self.fieldsHeight)
        fieldsTable.setAccessibilityLabel(TaggingModel.setting.title)
        ruleHeading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        problemLabel.textColor = .systemRed
        noteLabel.textColor = .secondaryLabelColor
        for label in [problemLabel, noteLabel] {
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.isHidden = true
        }
        revertButton.target = self
        revertButton.action = #selector(revert)
        saveButton.target = self
        saveButton.action = #selector(save)
        for button in [revertButton, saveButton] { button.bezelStyle = .rounded }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [spacer, revertButton, saveButton])
        let views = [summary, fields, ruleHeading, ruleForm(), problemLabel, noteLabel, buttons]
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        let margin = GeneralPane.margin
        stack.edgeInsets = NSEdgeInsets(top: margin, left: margin, bottom: margin, right: margin)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: GeneralPane.width).isActive = true
        for view in [summary, fields, problemLabel, noteLabel, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * margin)
                .isActive = true
        }
        view = stack
        // The file may have changed since the model was made.
        model.reload()
        fieldsTable.reloadData()
        fieldsTable.selectRowIndexes([0], byExtendingSelection: false)
        refresh()
    }

    /// A table with `columns` of their titles and widths, in a bordered scroll view `height`
    /// tall.
    private func scroll(
        _ table: NSTableView, columns: [(String, CGFloat)], height: CGFloat
    ) -> NSScrollView {
        for (title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(title))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.style = .fullWidth
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        return scroll
    }

    /// The selected rule's controls, a label column and a control column.
    private func ruleForm() -> NSGridView {
        modePopUp.addItems(withTitles: DiscogsFieldRule.Mode.shown.map(\.title))
        modePopUp.target = self
        modePopUp.action = #selector(modeChosen)
        let tags = scroll(
            tagsTable,
            columns: TagFormat.allCases.map { ($0.rawValue, 100) }
                + [(Self.numberedTitle, 100)],
            height: Self.tagsHeight)
        tagsTable.setAccessibilityLabel(DiscogsFieldRule.targetsTitle)
        tags.widthAnchor.constraint(equalToConstant: Self.controlWidth).isActive = true
        addTagButton.image = NSImage(
            systemSymbolName: "plus", accessibilityDescription: "Add a tag")
        addTagButton.target = self
        addTagButton.action = #selector(addTag)
        removeTagButton.image = NSImage(
            systemSymbolName: "minus", accessibilityDescription: "Remove the tag")
        removeTagButton.target = self
        removeTagButton.action = #selector(removeTag)
        for button in [addTagButton, removeTagButton] { button.bezelStyle = .smallSquare }
        let tagButtons = NSStackView(views: [addTagButton, removeTagButton])
        tagButtons.spacing = 0
        let tagsCell = NSStackView(views: [tags, tagButtons])
        tagsCell.orientation = .vertical
        tagsCell.alignment = .leading
        tagsCell.spacing = 4
        for (field, placeholder) in [(joinField, "No join"), (templateField, "The field's value")] {
            field.placeholderString = placeholder
            field.delegate = self
            field.widthAnchor.constraint(equalToConstant: Self.controlWidth).isActive = true
        }
        var rows: [[NSView]] = [
            [label(DiscogsFieldRule.modeTitle), modePopUp],
            [label(DiscogsFieldRule.targetsTitle), tagsCell],
            [label(DiscogsFieldRule.joinTitle), joinField],
            [label(DiscogsFieldRule.templateTitle), templateField],
        ]
        for (index, part) in TaggingModel.Part.all.enumerated() {
            let popUp = NSPopUpButton()
            popUp.tag = index
            popUp.addItems(withTitles: part.choices)
            popUp.toolTip = part.help
            popUp.target = self
            popUp.action = #selector(partChosen(_:))
            partPopUps.append(popUp)
            rows.append([label(part.title), popUp])
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        return grid
    }

    private func label(_ title: String) -> NSTextField {
        NSTextField(labelWithString: title + ":")
    }

    /// Reads the mapping again, after the config file or the app changed it.
    func reload() {
        let selected = fieldsTable.selectedRowIndexes
        model.reload()
        fieldsTable.reloadData()
        fieldsTable.selectRowIndexes(selected, byExtendingSelection: false)
        refresh()
    }

    /// Shows the selected field's rule, the draft's problem and note, and what can be saved.
    /// A field being typed in keeps its text.
    private func refresh() {
        let field = field
        let rule = model.draft[field]
        ruleHeading.stringValue = "\(Self.ruleTitle) for “\(field.title)”"
        modePopUp.selectItem(at: DiscogsFieldRule.Mode.shown.firstIndex(of: rule.mode) ?? -1)
        let texts = [(rule.format.join, joinField), (rule.format.template, templateField)]
        for (text, control) in texts where control.currentEditor() == nil {
            control.stringValue = text ?? ""
        }
        for (part, popUp) in zip(TaggingModel.Part.all, partPopUps) {
            popUp.selectItem(at: part.selected(in: rule.format))
        }
        if tagsTable.editedRow < 0 {
            tagsField = field
            tagsTable.reloadData()
        }
        removeTagButton.isEnabled = tagsTable.selectedRow >= 0
        showStatus()
    }

    /// The draft's problem, the note, the fields table's row for the field, and the buttons.
    private func showStatus() {
        let problem = model.problem
        problemLabel.stringValue = problem.map { "config.json wouldn't take this: \($0)" } ?? ""
        problemLabel.isHidden = problem == nil
        noteLabel.stringValue = model.note ?? ""
        noteLabel.isHidden = model.note == nil
        saveButton.isEnabled = model.canSave
        revertButton.isEnabled = model.isEdited
        let row = TaggingModel.fields.firstIndex(of: field)!
        fieldsTable.reloadData(
            forRowIndexes: [row], columnIndexes: IndexSet(0..<fieldsTable.numberOfColumns))
    }

    // MARK: Actions

    @objc private func modeChosen() {
        let modes = DiscogsFieldRule.Mode.shown
        guard modes.indices.contains(modePopUp.indexOfSelectedItem) else { return }
        model.draft[field].mode = modes[modePopUp.indexOfSelectedItem]
        refresh()
    }

    @objc private func partChosen(_ popUp: NSPopUpButton) {
        model.choose(popUp.indexOfSelectedItem, of: TaggingModel.Part.all[popUp.tag], for: field)
        refresh()
    }

    @objc func addTag() {
        let position = model.addTag(for: field)
        tagsTable.reloadData()
        tagsTable.selectRowIndexes([position], byExtendingSelection: false)
        tagsTable.editColumn(0, row: position, with: nil, select: true)
        refresh()
    }

    @objc func removeTag() {
        model.removeTag(at: tagsTable.selectedRow, for: tagsField)
        refresh()
    }

    @objc func save() {
        do {
            try model.save()
        } catch {
            logger.error("\(error)")
            problemLabel.stringValue = GeneralModel.refusal(error)
            problemLabel.isHidden = false
            return
        }
        refresh()
    }

    @objc func revert() {
        model.revert()
        refresh()
    }

    @objc private func numberedClicked(_ box: NSButton) {
        model.setNumbered(box.state == .on, at: box.tag, for: tagsField)
        refresh()
    }

    /// The join and the template change as they're typed, so the problem shows at once.
    func controlTextDidChange(_ notification: Notification) {
        guard let control = notification.object as? NSTextField else { return }
        if control === joinField {
            model.draft[field].setJoin(control.stringValue)
        } else if control === templateField {
            model.draft[field].setTemplate(control.stringValue)
        } else {
            return
        }
        showStatus()
    }

    /// A tag's spelling is taken when its cell's editing ends.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let cell = notification.object as? NSTextField,
            let id = cell.identifier?.rawValue,
            let format = TagFormat(rawValue: id)
        else { return }
        model.setTag(cell.stringValue, in: format, at: cell.tag, for: tagsField)
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    // MARK: Tables

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === fieldsTable ? TaggingModel.fields.count : model.tags(tagsField).count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        guard let id = tableColumn?.identifier.rawValue else { return nil }
        if tableView === fieldsTable {
            let field = TaggingModel.fields[row]
            let text = id == Self.fieldTitle ? field.title : model.ruleText(field)
            let label = NSTextField(labelWithString: text)
            label.lineBreakMode = .byTruncatingTail
            label.toolTip = id == Self.fieldTitle ? Self.keyTip(field) : text
            return label
        }
        let target = model.tags(tagsField)[row]
        guard let format = TagFormat(rawValue: id) else {
            let box = NSButton(
                checkboxWithTitle: "", target: self, action: #selector(numberedClicked(_:)))
            box.state = target.isNumbered ? .on : .off
            box.tag = row
            box.toolTip =
                target.numberedNames.map {
                    "Each value after the first gets a numbered key, as “\($0.vorbis)-2”"
                } ?? "One tag for every value"
            box.setAccessibilityLabel(Self.numberedTitle)
            return box
        }
        let cell = NSTextField(string: target.names[format])
        cell.isBordered = false
        cell.drawsBackground = false
        cell.identifier = NSUserInterfaceItemIdentifier(format.rawValue)
        cell.tag = row
        cell.delegate = self
        cell.placeholderString = "Tag or key"
        cell.setAccessibilityLabel("\(format.rawValue) spelling")
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        if table === fieldsTable {
            view.window?.makeFirstResponder(fieldsTable)
            refresh()
        } else {
            removeTagButton.isEnabled = tagsTable.selectedRow >= 0
        }
    }
}
