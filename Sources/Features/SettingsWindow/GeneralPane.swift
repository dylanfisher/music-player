import AppKit
import Commands
import Log
import Settings

private let logger = moduleLogger()

/// What a setting or a shortcut with no value shows.
let noValueText = "None"

/// Settings ▸ General: the config file's place and buttons, then the settings from the schema in
/// sections, a grid of rows each. Settings ▸ Appearance is one too, with its section alone and
/// no config file.
@MainActor
final class GeneralPane: NSViewController, NSTextFieldDelegate, NSMenuDelegate {
    static let width = 640.0
    /// How long Copy Default Config's button says "Copied".
    static let copiedSeconds = 1.5

    private let model: GeneralModel
    /// Nil for a pane without the config file's place and buttons.
    private let configPath: String?
    private let sections: [GeneralModel.Section]
    private let actions: SettingsActions
    private var controls: [String: NSView] = [:]
    private let copyButton = NSButton()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var copiedGeneration = 0
    private var syncFolderLabel: NSTextField?

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
        // One grid for every section, so the labels of all of them line up.
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        let shown = model.sections.filter { sections.contains($0.section) }
        for (index, (section, rows)) in shown.enumerated() {
            let heading = NSTextField(labelWithString: section.title)
            heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            let headingRow = grid.addRow(with: [NSGridCell.emptyContentView, heading])
            headingRow.topPadding = index == 0 ? 0 : 12
            for row in rows { addRow(row, to: grid) }
        }
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        let views = configPath.map { [configHeader($0), NSBox.separator()] } ?? []
        let stack = NSStackView(views: views + [grid, errorLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        view = stack
        reload()
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
        let label = NSTextField(labelWithString: row.title + ":")
        label.alignment = .right
        let summary = NSTextField(wrappingLabelWithString: row.summary)
        summary.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        summary.textColor = .secondaryLabelColor
        summary.preferredMaxLayoutWidth = 380
        let control = makeControl(row)
        controls[row.key] = control
        let cell = NSStackView(views: [control, summary])
        cell.orientation = .vertical
        cell.alignment = .leading
        cell.spacing = 3
        grid.addRow(with: [label, cell])
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func makeControl(_ row: GeneralModel.Row) -> NSView {
        switch row.control {
        case .checkbox:
            let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggled(_:)))
            box.identifier = NSUserInterfaceItemIdentifier(row.key)
            box.setAccessibilityLabel(row.title)
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
        case .number(_, let optional), .text(let optional):
            let field = NSTextField()
            field.identifier = NSUserInterfaceItemIdentifier(row.key)
            field.placeholderString = optional ? noValueText : nil
            field.delegate = self
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: row.control.isNumber ? 80 : 300)
                .isActive = true
            field.setAccessibilityLabel(row.title)
            return field
        case .syncFolder:
            let folder = NSTextField(labelWithString: "")
            folder.identifier = NSUserInterfaceItemIdentifier(row.key)
            folder.font = .monospacedSystemFont(
                ofSize: NSFont.smallSystemFontSize, weight: .regular)
            folder.isSelectable = true
            folder.lineBreakMode = .byTruncatingMiddle
            let choose = button("Choose…", #selector(chooseSyncFolder))
            let clear = button("Clear", #selector(clearSyncFolder(_:)))
            clear.identifier = NSUserInterfaceItemIdentifier(row.key)
            syncFolderLabel = folder
            return NSStackView(views: [folder, choose, clear])
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
        case .readOnly:
            let list = NSTextField(wrappingLabelWithString: "")
            list.identifier = NSUserInterfaceItemIdentifier(row.key)
            list.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            list.isSelectable = true
            list.preferredMaxLayoutWidth = 380
            return list
        }
    }

    /// Shows each setting's value as the config file has it now.
    func reload() {
        for row in model.rows {
            guard let control = controls[row.key] else { continue }
            switch row.control {
            case .checkbox: (control as? NSButton)?.state = model.isOn(row.key) ? .on : .off
            case .popUp:
                let popUp = control as? NSPopUpButton
                let raw = model.choice(row.key)
                popUp?.selectItem(
                    at: popUp?.itemArray.firstIndex { $0.representedObject as? String == raw } ?? -1
                )
            case .number, .text:
                guard let field = control as? NSTextField, field.currentEditor() == nil else {
                    continue
                }
                field.stringValue = model.text(row.key)
            case .output:
                (control as? NSPopUpButton).map(showOutputs)
            case .folders:
                preconditionFailure("the Watched Folders pane lists \(row.key)")
            case .renderer:
                preconditionFailure("the output device's row lists \(row.key)")
            case .syncFolder:
                syncFolderLabel?.stringValue = model.syncFolder(row.key) ?? noValueText
            case .readOnly:
                (control as? NSTextField)?.stringValue =
                    model.text(row.key) + " (edit in the config file)"
            }
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
        view.window?.makeFirstResponder(control)
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

    @objc private func clearSyncFolder(_ button: NSButton) {
        guard let key = button.identifier?.rawValue else { return }
        attempt { try model.clear(key) }
    }

    @objc private func toggled(_ box: NSButton) {
        guard let key = box.identifier?.rawValue else { return }
        attempt { try model.setOn(key, box.state == .on) }
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

extension NSBox {
    static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}
