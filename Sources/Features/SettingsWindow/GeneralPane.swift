import AppKit
import Log
import Settings

private let logger = moduleLogger()

/// Settings ▸ General: the config file's place and buttons, then a row per setting from the
/// schema in a grid.
@MainActor
final class GeneralPane: NSViewController, NSTextFieldDelegate {
    static let width = 640.0
    /// How long Copy Default Config's button says "Copied".
    static let copiedSeconds = 1.5

    private let model: GeneralModel
    private let configPath: String
    private let actions: SettingsActions
    private var controls: [String: NSView] = [:]
    private let copyButton = NSButton()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var copiedGeneration = 0

    init(model: GeneralModel, configPath: String, actions: SettingsActions) {
        self.model = model
        self.configPath = configPath
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    override func loadView() {
        let path = NSTextField(
            labelWithString: (configPath as NSString).abbreviatingWithTildeInPath)
        path.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        path.textColor = .secondaryLabelColor
        path.lineBreakMode = .byTruncatingMiddle
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let open = button("Open Config File", #selector(openConfig))
        let reveal = button("Reveal in Finder", #selector(revealConfig))
        copyButton.title = "Copy Default Config"
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

        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 14
        grid.columnSpacing = 12
        for row in model.rows {
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
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        let stack = NSStackView(views: [header, NSBox.separator(), grid, errorLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        view = stack
        reload()
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
            field.placeholderString = optional ? "None" : nil
            field.delegate = self
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: row.control.isNumber ? 80 : 300)
                .isActive = true
            field.setAccessibilityLabel(row.title)
            return field
        case .folders, .readOnly:
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
            case .folders:
                let paths = model.folders(row.key)
                (control as? NSTextField)?.stringValue =
                    paths.isEmpty
                    ? "None. Add folders with + in the sidebar." : paths.joined(separator: "\n")
            case .readOnly:
                (control as? NSTextField)?.stringValue =
                    model.text(row.key) + " (edit in the config file)"
            }
        }
    }

    /// Scrolls to a setting's row and gives its control the keys, for the palette.
    func focus(_ key: String) {
        guard let control = controls[key] else { return }
        control.scrollToVisible(control.bounds)
        view.window?.makeFirstResponder(control)
    }

    private func attempt(_ change: () throws -> Void) {
        do {
            try change()
            errorLabel.isHidden = true
        } catch {
            logger.error("\(error)")
            errorLabel.stringValue = "\(error)"
            errorLabel.isHidden = false
            reload()
        }
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

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let key = field.identifier?.rawValue
        else { return }
        attempt { try model.setText(key, field.stringValue) }
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
            self.copyButton.title = "Copy Default Config"
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
