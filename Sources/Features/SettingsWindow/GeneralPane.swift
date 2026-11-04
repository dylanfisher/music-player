import AppKit
import Commands
import Log
import Settings

private let logger = moduleLogger()

/// What a setting or a shortcut with no value shows.
let noValueText = "None"

/// Settings ▸ General: the config file's place and buttons, then the settings from the schema,
/// a titled box for each section. A checkbox carries its setting's title on its right; a pop-up
/// or a field has the title on its left, in one column for the whole pane. Each setting's
/// summary is under it. Settings ▸ Appearance is one too, with its section alone and no config
/// file, and the Watched Folders pane holds one for its section.
@MainActor
final class GeneralPane: NSViewController, NSTextFieldDelegate, NSMenuDelegate {
    static let width = 640.0
    /// How long Copy Default Config's button says "Copied".
    static let copiedSeconds = 1.5
    /// The space around the pane's boxes.
    static let margin = 20.0
    /// The space between a box's edge and its rows.
    private static let boxInset = 12.0
    /// How far a checkbox's title is from its left edge, where its summary starts too.
    private static let checkboxIndent = 20.0
    /// The widest a summary is, so the boxes keep the pane's width.
    private static let summaryWidth = 400.0

    private let model: GeneralModel
    /// Nil for a pane without the config file's place and buttons.
    private let configPath: String?
    private let sections: [GeneralModel.Section]
    private let actions: SettingsActions
    private var controls: [String: NSView] = [:]
    /// The number and text rows' fields, which may sit beside a unit.
    private var fields: [String: NSTextField] = [:]
    /// The rows' labels on the left, for rows that have one, and their summaries, which dim
    /// while the row is disabled.
    private var labels: [String: NSTextField] = [:]
    private var summaries: [String: NSTextField] = [:]
    private let copyButton = NSButton()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var copiedGeneration = 0
    private var syncFolderLabel: NSTextField?
    private var syncFolderButtons: (change: NSButton, open: NSButton, clear: NSButton)?
    /// The color rows' wells, and their Default buttons, which set null.
    private var colorWells: [String: NSColorWell] = [:]
    private var colorDefaults: [String: NSButton] = [:]
    /// The bar builders opened from this pane, by key, kept so a reopen shows the same one.
    private(set) var barBuilders: [String: BarBuilderWindow] = [:]
    /// The tokens' popover while it shows, for tests.
    private(set) var tokensPopover: NSPopover?

    init(
        model: GeneralModel, configPath: String?, actions: SettingsActions,
        sections: [GeneralModel.Section] = GeneralModel.Section.allCases
    ) {
        self.model = model
        self.configPath = configPath
        self.sections = sections
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    override func loadView() {
        let shown = model.sections.filter { sections.contains($0.section) }
        let grids = shown.map { grid($0.rows) }
        // One label column width for every box, so the controls of all of them line up.
        let labelWidth =
            grids.flatMap { grid in
                (0..<grid.numberOfRows).compactMap { grid.cell(atColumnIndex: 0, rowIndex: $0) }
            }
            .compactMap { $0.contentView?.fittingSize.width }.max() ?? 0
        for grid in grids { grid.column(at: 0).width = labelWidth }
        let boxes = zip(shown, grids).map { box($0.section.title, $1) }
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        let views = configPath.map { [configHeader($0)] } ?? []
        let stack = NSStackView(views: views + boxes + [errorLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(
            top: Self.margin, left: Self.margin, bottom: Self.margin, right: Self.margin)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        for box in boxes {
            box.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Self.margin)
                .isActive = true
        }
        view = stack
        reload()
    }

    /// A section's rows, in a grid of a label column and a control column.
    private func grid(_ rows: [GeneralModel.Row]) -> NSGridView {
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 10
        grid.columnSpacing = 8
        for row in rows { addRow(row, to: grid) }
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        return grid
    }

    /// A section's title over its rows in a box, as Swinsian's are. The box only draws behind
    /// the rows: an `NSBox`'s own content view doesn't size the box from its constraints.
    private func box(_ title: String, _ content: NSView) -> NSView {
        let background = NSBox()
        background.boxType = .custom
        background.fillColor = .quaternaryLabelColor.withAlphaComponent(0.05)
        background.borderColor = .separatorColor
        background.cornerRadius = 6
        let panel = NSView()
        for view in [background, content] {
            view.translatesAutoresizingMaskIntoConstraints = false
            panel.addSubview(view)
        }
        let inset = Self.boxInset
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            background.topAnchor.constraint(equalTo: panel.topAnchor),
            background.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(
                lessThanOrEqualTo: panel.trailingAnchor, constant: -inset),
            content.topAnchor.constraint(equalTo: panel.topAnchor, constant: inset),
            content.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -inset),
        ])
        let heading = NSTextField(labelWithString: title)
        let section = NSStackView(views: [heading, panel])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 5
        panel.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        section.translatesAutoresizingMaskIntoConstraints = false
        return section
    }

    /// The config file's place, and buttons to open, reveal and copy it.
    private func configHeader(_ configPath: String) -> NSView {
        let path = NSTextField(
            labelWithString: (configPath as NSString).abbreviatingWithTildeInPath)
        path.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        path.textColor = .secondaryLabelColor
        path.lineBreakMode = .byTruncatingMiddle
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let open = button(AppCommands.title(of: .openConfigFile), #selector(openConfig))
        let reveal = button("Reveal in Finder", #selector(revealConfig))
        copyButton.title = AppCommands.title(of: .copyDefaultConfig)
        copyButton.bezelStyle = .rounded
        copyButton.target = self
        copyButton.action = #selector(copyDefault)
        // Kept at its widest title's width, so "Copied" doesn't move the row.
        copyButton.widthAnchor.constraint(equalToConstant: copyButton.fittingSize.width).isActive =
            true
        let buttons = NSStackView(views: [open, reveal, copyButton])
        let header = NSStackView(views: [path, buttons])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 6
        return header
    }

    private func addRow(_ row: GeneralModel.Row, to grid: NSGridView) {
        let summary = NSTextField(wrappingLabelWithString: row.summary)
        summary.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        summary.textColor = .secondaryLabelColor
        summary.preferredMaxLayoutWidth = Self.summaryWidth
        summaries[row.key] = summary
        let control = makeControl(row)
        controls[row.key] = control
        // A checkbox's summary sits under its title, not under the box itself.
        let indented = NSStackView(views: [summary])
        indented.edgeInsets.left = row.control == .checkbox ? Self.checkboxIndent : 0
        let cell = NSStackView(views: [control, indented])
        cell.orientation = .vertical
        cell.alignment = .leading
        cell.spacing = 2
        guard row.control != .checkbox else {
            grid.addRow(with: [NSGridCell.emptyContentView, cell])
            return
        }
        let label = NSTextField(labelWithString: row.title + ":")
        label.alignment = .right
        labels[row.key] = label
        grid.addRow(with: [label, cell])
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    /// A number, text or template row's field.
    private func textField(_ row: GeneralModel.Row, optional: Bool) -> NSTextField {
        let field = NSTextField()
        field.identifier = NSUserInterfaceItemIdentifier(row.key)
        field.placeholderString = optional ? noValueText : nil
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: row.control.isNumber ? 60 : 300)
            .isActive = true
        field.setAccessibilityLabel(row.title)
        fields[row.key] = field
        return field
    }

    /// Lists a template's tokens in a popover under its help button.
    @objc private func showTokens(_ button: NSButton) {
        let list = NSTextField(labelWithString: button.toolTip ?? "")
        list.isSelectable = true
        let content = NSViewController()
        content.view = NSStackView(views: [list])
        (content.view as? NSStackView)?.edgeInsets = NSEdgeInsets(
            top: Self.boxInset, left: Self.boxInset, bottom: Self.boxInset, right: Self.boxInset)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = content
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        tokensPopover = popover
    }

    private func makeControl(_ row: GeneralModel.Row) -> NSView {
        switch row.control {
        case .checkbox:
            let box = NSButton(
                checkboxWithTitle: row.title, target: self, action: #selector(toggled(_:)))
            box.identifier = NSUserInterfaceItemIdentifier(row.key)
            return box
        case .popUp(let choices):
            let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
            for choice in choices {
                popUp.addItem(withTitle: choice.title)
                popUp.lastItem?.representedObject = choice.rawValue
            }
            popUp.identifier = NSUserInterfaceItemIdentifier(row.key)
            popUp.target = self
            popUp.action = #selector(chose(_:))
            popUp.setAccessibilityLabel(row.title)
            return popUp
        case .template(let tokens):
            let field = textField(row, optional: false)
            let help = NSButton(title: "", target: self, action: #selector(showTokens(_:)))
            help.bezelStyle = .helpButton
            help.toolTip = GeneralModel.help(tokens)
            help.setAccessibilityLabel("Tokens for \(row.title)")
            return NSStackView(views: [field, help])
        case .number(_, let optional), .text(let optional):
            let field = textField(row, optional: optional)
            guard let unit = row.unit else { return field }
            return NSStackView(views: [field, NSTextField(labelWithString: unit)])
        case .syncFolder:
            let folder = NSTextField(labelWithString: "")
            folder.lineBreakMode = .byTruncatingTail
            folder.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            folder.setAccessibilityLabel(row.title)
            let change = button("", #selector(chooseSyncFolder))
            let open = button("Open", #selector(openSyncFolder))
            let clear = button("Clear", #selector(clearSyncFolder(_:)))
            clear.identifier = NSUserInterfaceItemIdentifier(row.key)
            syncFolderLabel = folder
            syncFolderButtons = (change, open, clear)
            let stack = NSStackView(views: [folder, change, open, clear])
            stack.identifier = NSUserInterfaceItemIdentifier(row.key)
            return stack
        case .output:
            let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
            popUp.identifier = NSUserInterfaceItemIdentifier(row.key)
            popUp.target = self
            popUp.action = #selector(choseOutput(_:))
            popUp.menu?.delegate = self
            popUp.setAccessibilityLabel(row.title)
            return popUp
        case .folders:
            preconditionFailure("the Watched Folders pane lists \(row.key)")
        case .renderer:
            preconditionFailure("the output device's row lists \(row.key)")
        case .barLayout:
            let edit = button("Edit Layout…", #selector(editBarLayout(_:)))
            edit.identifier = NSUserInterfaceItemIdentifier(row.key)
            edit.setAccessibilityLabel(row.title)
            return edit
        case .color(let optional):
            let well = NSColorWell()
            well.identifier = NSUserInterfaceItemIdentifier(row.key)
            well.target = self
            well.action = #selector(choseColor(_:))
            // One change when the panel lets go, not a config file write for each drag step.
            well.isContinuous = false
            well.setAccessibilityLabel(row.title)
            NSColorPanel.shared.showsAlpha = true
            colorWells[row.key] = well
            guard optional else { return well }
            let reset = button("Default", #selector(defaultColor(_:)))
            reset.identifier = NSUserInterfaceItemIdentifier(row.key)
            colorDefaults[row.key] = reset
            return NSStackView(views: [well, reset])
        case .readOnly:
            let list = NSTextField(wrappingLabelWithString: "")
            list.identifier = NSUserInterfaceItemIdentifier(row.key)
            list.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            list.isSelectable = true
            list.preferredMaxLayoutWidth = Self.summaryWidth
            return list
        }
    }

    /// Shows each setting's value as the config file has it now, and which rows can change.
    func reload() {
        for row in model.rows {
            guard let control = controls[row.key] else { continue }
            show(row, in: control)
            let enabled = model.isEnabled(row.key)
            (fields[row.key] ?? control as? NSControl)?.isEnabled = enabled
            labels[row.key]?.textColor = enabled ? .labelColor : .disabledControlTextColor
            summaries[row.key]?.textColor =
                enabled ? .secondaryLabelColor : .disabledControlTextColor
        }
    }

    private func show(_ row: GeneralModel.Row, in control: NSView) {
        switch row.control {
        case .checkbox: (control as? NSButton)?.state = model.isOn(row.key) ? .on : .off
        case .popUp:
            let popUp = control as? NSPopUpButton
            let raw = model.choice(row.key)
            popUp?.selectItem(
                at: popUp?.itemArray.firstIndex { $0.representedObject as? String == raw } ?? -1)
        case .number, .text, .template:
            guard let field = fields[row.key], field.currentEditor() == nil
            else { return }
            field.stringValue = model.text(row.key)
        case .output:
            (control as? NSPopUpButton).map(showOutputs)
        case .folders:
            preconditionFailure("the Watched Folders pane lists \(row.key)")
        case .renderer:
            preconditionFailure("the output device's row lists \(row.key)")
        case .syncFolder:
            let name = model.syncFolderName(row.key)
            syncFolderLabel?.stringValue = name ?? noValueText
            syncFolderLabel?.toolTip = model.syncFolder(row.key)
            syncFolderButtons?.change.title = name == nil ? "Choose…" : "Change…"
            syncFolderButtons?.open.isEnabled = name != nil
            syncFolderButtons?.clear.isEnabled = name != nil
        case .barLayout:
            barBuilders[row.key]?.reload()
        case .color:
            let color = model.color(row.key)?.components
            // Null is the system's grid color, as the track table draws it.
            colorWells[row.key]?.color =
                color.map {
                    NSColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: $0.alpha)
                } ?? .gridColor
            colorDefaults[row.key]?.isEnabled = color != nil
        case .readOnly:
            (control as? NSTextField)?.stringValue =
                model.text(row.key) + " (edit in the config file)"
        }
    }

    /// Lists the outputs found, by name, with the one the config names picked. Items are added
    /// to the menu directly, since two devices can share a name.
    private func showOutputs(_ popUp: NSPopUpButton) {
        let picked = model.output
        let options = actions.outputs()
        popUp.removeAllItems()
        for option in options {
            let item = NSMenuItem(title: option.title, action: nil, keyEquivalent: "")
            item.representedObject = option.choice.text
            popUp.menu?.addItem(item)
        }
        popUp.selectItem(at: options.firstIndex { $0.choice == picked } ?? -1)
    }

    func menuWillOpen(_ menu: NSMenu) { actions.searchOutputs() }

    /// Scrolls to a setting's row and gives its control the keys, for the palette.
    func focus(_ key: String) {
        guard let control = controls[key] else { return }
        control.scrollToVisible(control.bounds)
        view.window?.makeFirstResponder(fields[key] ?? control)
    }

    /// Makes the change, or shows why it was refused and the values in effect. False when it
    /// was refused.
    @discardableResult
    private func attempt(_ change: () throws -> Void) -> Bool {
        do {
            try change()
            errorLabel.isHidden = true
            return true
        } catch {
            logger.error("\(error)")
            errorLabel.stringValue = "\(error)"
            errorLabel.isHidden = false
            reload()
            return false
        }
    }

    @objc private func chooseSyncFolder() { actions.chooseSyncFolder() }

    @objc private func editBarLayout(_ sender: NSButton) {
        sender.identifier.map { showBarBuilder($0.rawValue) }
    }

    /// Opens the bar builder on the bar layout setting `key`, made on first use.
    func showBarBuilder(_ key: String) {
        if let builder = barBuilders[key] { return builder.showWindow() }
        attempt {
            let builder = BarBuilderWindow(model: try model.barBuilder(key))
            barBuilders[key] = builder
            builder.showWindow()
        }
    }

    @objc private func openSyncFolder() { actions.openSyncFolder() }

    @objc private func choseColor(_ well: NSColorWell) {
        guard let key = well.identifier?.rawValue,
            let color = well.color.usingColorSpace(.sRGB)
        else { return }
        attempt {
            try model.setColor(
                key,
                HexColor(
                    red: color.redComponent, green: color.greenComponent,
                    blue: color.blueComponent, alpha: color.alphaComponent))
        }
    }

    @objc private func defaultColor(_ button: NSButton) {
        guard let key = button.identifier?.rawValue else { return }
        attempt { try model.clear(key) }
    }

    @objc private func clearSyncFolder(_ button: NSButton) {
        guard let key = button.identifier?.rawValue else { return }
        attempt { try model.clear(key) }
    }

    @objc private func toggled(_ box: NSButton) {
        guard let key = box.identifier?.rawValue else { return }
        attempt { try model.setOn(key, box.state == .on) }
        // The rows that depend on this one follow it at once, before the file's change comes
        // back.
        reload()
    }

    @objc private func chose(_ popUp: NSPopUpButton) {
        guard let key = popUp.identifier?.rawValue,
            let raw = popUp.selectedItem?.representedObject as? String
        else { return }
        attempt { try model.setChoice(key, raw) }
    }

    @objc private func choseOutput(_ popUp: NSPopUpButton) {
        guard let text = popUp.selectedItem?.representedObject as? String,
            let choice = OutputChoice(text: text)
        else { return }
        actions.chooseOutput(choice)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let key = field.identifier?.rawValue
        else { return }
        // The field may still be the one being edited, which `reload` leaves alone, so a value
        // the setting refused is put back here.
        if !attempt({ try model.setText(key, field.stringValue) }) {
            field.stringValue = model.text(key)
        }
    }

    @objc private func openConfig() { actions.openConfigFile() }

    @objc private func revealConfig() { actions.revealConfigFile() }

    /// The button says "Copied" for 1.5 s, at the same width, and VoiceOver hears it.
    @objc private func copyDefault() {
        actions.copyDefaultConfig()
        copiedGeneration += 1
        let mine = copiedGeneration
        copyButton.title = "Copied"
        NSAccessibility.post(
            element: copyButton, notification: .announcementRequested,
            userInfo: [
                .announcement: "Copied", .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.copiedSeconds) { [weak self] in
            guard let self, self.copiedGeneration == mine else { return }
            self.copyButton.title = AppCommands.title(of: .copyDefaultConfig)
        }
    }
}

extension GeneralModel.Control {
    var isNumber: Bool {
        if case .number = self { return true }
        return false
    }
}
