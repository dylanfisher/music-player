import AppKit
import Commands
import DisplayText
import Log
import Settings

private let logger = moduleLogger()

/// What a setting or a shortcut with no value shows.
let noValueText = "None"

/// Settings ▸ General: the config file's place and buttons in a box titled Config, then the
/// settings from the schema, a titled box for each section. A checkbox carries its setting's
/// title on its right; a pop-up or a field has the title on its left, in one column for the
/// whole pane. Each setting's summary is under it. Settings ▸ Playback, Appearance and Toolbar are one too, with their
/// sections and no config file, and the Watched Folders pane holds one for its sections.
@MainActor
final class GeneralPane: NSViewController, NSTextFieldDelegate, NSMenuDelegate {
    static let width = 640.0
    /// The title of the box of the config file's place and buttons.
    static let configTitle = "Config"
    /// The config file's and the database's button that shows the file in Finder.
    private static let revealTitle = "Reveal in Finder"
    /// How long Copy Default Config's button says "Copied".
    static let copiedSeconds = 1.5
    /// How long a color well's color stays the same before it's saved: a drag in the color
    /// panel changes it at every step, and each save writes the config file.
    static let colorPauseSeconds = 0.25
    /// The space around the pane's boxes.
    static let margin = DialogMargin.value
    /// The space between a box's edge and its rows.
    private static let boxInset = 12.0
    /// The sections' boxes' look, which the bar builder's preview takes too.
    static let boxFill = NSColor.quaternaryLabelColor.withAlphaComponent(0.05)
    static let boxCornerRadius = 6.0
    /// How far a checkbox's title is from its left edge, where its summary starts too.
    private static let checkboxIndent = 20.0
    /// The widest a summary is, so the boxes keep the pane's width.
    private static let summaryWidth = 400.0
    /// A color well's width, which otherwise stretches across the row.
    private static let colorWellWidth = 44.0

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
    /// Show Library Health, in the Library section; nil in a pane without that section.
    private(set) var healthButton: NSButton?
    private var syncFolderButtons: (change: NSButton, open: NSButton, clear: NSButton)?
    /// The folder rows' paths and buttons, by key.
    private var folderLabels: [String: NSTextField] = [:]
    private var folderButtons: [String: (change: NSButton, clear: NSButton)] = [:]
    /// The Library section's database rows (ADR 0142), nil in a pane without that section.
    private(set) var indexPathLabel: NSTextField?
    private(set) var indexSizeLabel: NSTextField?
    private(set) var lastSnapshotLabel: NSTextField?
    private(set) var backUpButton: NSButton?
    private(set) var restoreButton: NSButton?
    private let backUpSpinner = NSProgressIndicator()
    private(set) var snapshotList: SnapshotList?
    /// Counts the database's reads, so an older one that ends later shows nothing.
    private var databaseReads = 0
    /// The template rows' lines under their fields, saying why the text typed isn't saved.
    private var templateProblems: [String: NSTextField] = [:]
    /// The color rows' wells, and their Default buttons, which set null.
    private var colorWells: [String: NSColorWell] = [:]
    private var colorDefaults: [String: NSButton] = [:]
    /// Counts each color row's changes, so a save waiting out the pause knows a newer one
    /// replaced it.
    private var colorGenerations: [String: Int] = [:]
    /// The rows hidden under disclosures, by key, and the disclosures' triangles: the fallback
    /// rows until opened or given a value, and the snapshot list under `snapshotsKey`.
    private(set) var fallbackRows: [String: NSGridRow] = [:]
    private(set) var disclosures: [String: NSButton] = [:]
    /// Each row group's line of buttons, by the group's title, which its later rows join.
    private var groupButtons: [String: NSStackView] = [:]
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
        if let library = shown.firstIndex(where: { $0.section == .library }) {
            addHealthRow(to: grids[library])
            addIndexRow(to: grids[library])
            addSnapshotRows(to: grids[library])
        }
        // One label column width for every box, so the controls of all of them line up.
        let labelWidth =
            grids.flatMap { grid in
                (0..<grid.numberOfRows).compactMap { grid.cell(atColumnIndex: 0, rowIndex: $0) }
            }
            .compactMap { $0.contentView?.fittingSize.width }.max() ?? 0
        for grid in grids { grid.column(at: 0).width = labelWidth }
        let config = configPath.map { [box(Self.configTitle, configHeader($0))] } ?? []
        let boxes = config + zip(shown, grids).map { box($0.section.title, $1) }
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        let stack = NSStackView(views: boxes + [errorLabel])
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
        background.fillColor = Self.boxFill
        background.borderColor = .separatorColor
        background.cornerRadius = Self.boxCornerRadius
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
        let reveal = button(Self.revealTitle, #selector(revealConfig))
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
        if let group = row.group, let buttons = groupButtons[group.title] {
            let control = makeControl(row)
            controls[row.key] = control
            buttons.addArrangedSubview(control)
            return
        }
        let summary = NSTextField(wrappingLabelWithString: row.group?.summary ?? row.summary)
        summary.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        summary.textColor = .secondaryLabelColor
        summary.preferredMaxLayoutWidth = Self.summaryWidth
        summaries[row.key] = summary
        let control = makeControl(row)
        controls[row.key] = control
        var shown = control
        if let group = row.group {
            let buttons = NSStackView(views: [control])
            groupButtons[group.title] = buttons
            shown = buttons
        }
        // A checkbox's summary sits under its title, not under the box itself.
        let indented = NSStackView(views: [summary])
        indented.edgeInsets.left = row.control == .checkbox ? Self.checkboxIndent : 0
        let cell = NSStackView(views: [shown, indented])
        cell.orientation = .vertical
        cell.alignment = .leading
        cell.spacing = 2
        if let disclosure = row.disclosure {
            grid.addRow(with: [NSGridCell.emptyContentView, disclosureLine(disclosure, row.key)])
        }
        defer {
            if row.disclosure != nil {
                let added = grid.row(at: grid.numberOfRows - 1)
                added.isHidden = model.text(row.key).isEmpty
                fallbackRows[row.key] = added
                disclosures[row.key]?.state = added.isHidden ? .off : .on
            }
        }
        guard row.control != .checkbox else {
            grid.addRow(with: [NSGridCell.emptyContentView, cell])
            return
        }
        let label = NSTextField(labelWithString: (row.group?.title ?? row.title) + ":")
        label.alignment = .right
        labels[row.key] = label
        grid.addRow(with: [label, cell])
    }

    /// Show Library Health's button, the last row of the Library section, with what it shows
    /// under it as a setting's summary is.
    private func addHealthRow(to grid: NSGridView) {
        let open = button(AppCommands.title(of: .checkHealth), #selector(showHealth))
        healthButton = open
        let summary = NSTextField(
            wrappingLabelWithString:
                "Shows the library's problems, such as files that couldn't be read, likely"
                + " duplicates and missing tags, over the track table.")
        summary.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        summary.textColor = .secondaryLabelColor
        summary.preferredMaxLayoutWidth = Self.summaryWidth
        let cell = NSStackView(views: [open, summary])
        cell.orientation = .vertical
        cell.alignment = .leading
        cell.spacing = 2
        grid.addRow(with: [NSGridCell.emptyContentView, cell])
    }

    @objc private func showHealth() { actions.showHealth() }

    /// The index's path and size, and a button to show it in Finder, after Show Library Health.
    private func addIndexRow(to grid: NSGridView) {
        let path = NSTextField(labelWithString: "")
        path.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        path.lineBreakMode = .byTruncatingMiddle
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let size = NSTextField(labelWithString: "")
        size.textColor = .secondaryLabelColor
        indexPathLabel = path
        indexSizeLabel = size
        let reveal = button(Self.revealTitle, #selector(revealIndex))
        let line = NSStackView(views: [path, size, reveal])
        grid.addRow(with: [NSTextField(labelWithString: "Database:"), line])
    }

    /// The key the snapshot list's row and disclosure go under.
    static let snapshotsKey = "library.snapshots"

    /// The last snapshot's time with Back Up Now, then a disclosure, closed at first, over the
    /// snapshots with Restore…, which would make the Library section the pane's tallest.
    private func addSnapshotRows(to grid: NSGridView) {
        let last = NSTextField(wrappingLabelWithString: "")
        last.preferredMaxLayoutWidth = Self.summaryWidth
        lastSnapshotLabel = last
        let backUp = button("Back Up Now", #selector(backUpNow))
        backUpButton = backUp
        backUpSpinner.style = .spinning
        backUpSpinner.controlSize = .small
        backUpSpinner.isDisplayedWhenStopped = false
        let line = NSStackView(views: [last, backUp, backUpSpinner])
        grid.addRow(with: [NSTextField(labelWithString: "Last Snapshot:"), line])
        let list = SnapshotList()
        let restore = button("Restore…", #selector(restoreSnapshot))
        restore.isEnabled = false
        list.selectionChanged = { [weak self, weak list] in
            self?.restoreButton?.isEnabled = list?.selected != nil
        }
        snapshotList = list
        restoreButton = restore
        let summary = NSTextField(
            wrappingLabelWithString:
                "A snapshot is written once a day and kept for a week, then one a week for four"
                + " more. Restoring one replaces the plays, ratings and playlists too.")
        summary.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        summary.textColor = .secondaryLabelColor
        summary.preferredMaxLayoutWidth = Self.summaryWidth
        let cell = NSStackView(views: [list.scroll, restore, summary])
        cell.orientation = .vertical
        cell.alignment = .leading
        cell.spacing = 6
        grid.addRow(with: [NSGridCell.emptyContentView, disclosureLine("Snapshots", Self.snapshotsKey)])
        let row = grid.addRow(with: [NSTextField(labelWithString: "Snapshots:"), cell])
        row.isHidden = true
        fallbackRows[Self.snapshotsKey] = row
    }

    /// Reads the index's size and the snapshots off the main actor and shows them; a pane
    /// without the Library section reads nothing.
    func showDatabase() async {
        guard indexPathLabel != nil else { return }
        databaseReads += 1
        let read = databaseReads
        do {
            let database = try await actions.libraryDatabase()
            guard read == databaseReads else { return }
            indexPathLabel?.stringValue = database.pathText
            indexPathLabel?.toolTip = database.indexPath
            indexSizeLabel?.stringValue = database.sizeText
            lastSnapshotLabel?.stringValue = database.lastSnapshotText
            snapshotList?.snapshots = database.snapshots
            restoreButton?.isEnabled = snapshotList?.selected != nil
        } catch {
            guard read == databaseReads else { return }
            logger.error("couldn't read the library's files: \(error)")
            lastSnapshotLabel?.stringValue = "The snapshots couldn't be read: \(error)"
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        Task { await showDatabase() }
    }

    @objc private func revealIndex() { actions.revealIndex() }

    @objc private func backUpNow() {
        backUpButton?.isEnabled = false
        backUpSpinner.startAnimation(nil)
        Task {
            await actions.backUpNow()
            backUpSpinner.stopAnimation(nil)
            backUpButton?.isEnabled = true
            await showDatabase()
        }
    }

    @objc private func restoreSnapshot() {
        guard let snapshot = snapshotList?.selected else { return }
        actions.restoreSnapshot(snapshot)
    }

    /// A disclosure triangle and `title`, which show and hide the row `key` under them.
    private func disclosureLine(_ title: String, _ key: String) -> NSView {
        let triangle = NSButton(title: "", target: self, action: #selector(disclose(_:)))
        triangle.bezelStyle = .disclosure
        triangle.setButtonType(.pushOnPushOff)
        triangle.setAccessibilityLabel(title)
        disclosures[key] = triangle
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        return NSStackView(views: [triangle, label])
    }

    @objc private func disclose(_ triangle: NSButton) {
        guard let key = disclosures.first(where: { $0.value === triangle })?.key else { return }
        fallbackRows[key]?.isHidden = triangle.state == .off
        (parent as? PaneScroller)?.fit()
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
        let stack = NSStackView(views: [list])
        stack.edgeInsets = NSEdgeInsets(
            top: Self.boxInset, left: Self.boxInset, bottom: Self.boxInset, right: Self.boxInset)
        // The popover takes the view's frame, which is the label's until it's set here, and
        // the insets then show only at the sides.
        stack.frame.size = stack.fittingSize
        let content = NSViewController()
        content.view = stack
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
            let problem = NSTextField(wrappingLabelWithString: "")
            problem.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            problem.textColor = .systemRed
            problem.preferredMaxLayoutWidth = Self.summaryWidth
            problem.isHidden = true
            templateProblems[row.key] = problem
            let stack = NSStackView(views: [NSStackView(views: [field, help]), problem])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 2
            return stack
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
        case .stagingFolder:
            let folder = NSTextField(labelWithString: "")
            folder.lineBreakMode = .byTruncatingTail
            folder.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            folder.setAccessibilityLabel(row.title)
            let change = button("", #selector(chooseStagingFolder))
            let clear = button("Clear", #selector(clearSyncFolder(_:)))
            clear.identifier = NSUserInterfaceItemIdentifier(row.key)
            folderLabels[row.key] = folder
            folderButtons[row.key] = (change, clear)
            let stack = NSStackView(views: [folder, change, clear])
            stack.identifier = NSUserInterfaceItemIdentifier(row.key)
            return stack
        case .folder:
            let folder = NSTextField(labelWithString: "")
            folder.lineBreakMode = .byTruncatingMiddle
            folder.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            folder.setAccessibilityLabel(row.title)
            let change = button("", #selector(chooseFolder(_:)))
            let clear = button("Clear", #selector(clearFolder(_:)))
            for button in [change, clear] {
                button.identifier = NSUserInterfaceItemIdentifier(row.key)
            }
            folderLabels[row.key] = folder
            folderButtons[row.key] = (change, clear)
            let stack = NSStackView(views: [folder, change, clear])
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
            let edit = button(
                row.group?.buttonTitle ?? "Edit Layout…", #selector(editBarLayout(_:)))
            edit.identifier = NSUserInterfaceItemIdentifier(row.key)
            edit.setAccessibilityLabel(row.title)
            return edit
        case .color(let optional):
            let well = NSColorWell()
            well.identifier = NSUserInterfaceItemIdentifier(row.key)
            well.target = self
            well.action = #selector(choseColor(_:))
            // A well that isn't continuous gets the panel's color but sends no action at all.
            well.isContinuous = true
            well.setAccessibilityLabel(row.title)
            well.translatesAutoresizingMaskIntoConstraints = false
            well.widthAnchor.constraint(equalToConstant: Self.colorWellWidth).isActive = true
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
            // A value set in the config file opens its fallback row, so it's never hidden.
            if let fallback = fallbackRows[row.key], !model.text(row.key).isEmpty {
                fallback.isHidden = false
                disclosures[row.key]?.state = .on
            }
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
        case .stagingFolder:
            let name = model.syncFolderName(row.key)
            folderLabels[row.key]?.stringValue = name ?? noValueText
            folderLabels[row.key]?.toolTip = model.syncFolder(row.key)
            folderButtons[row.key]?.change.title = name == nil ? "Choose…" : "Change…"
            folderButtons[row.key]?.clear.isEnabled = name != nil
        case .folder(let emptyText, _):
            let path = model.text(row.key)
            let enabled = model.isEnabled(row.key)
            let label = folderLabels[row.key]
            let buttons = folderButtons[row.key]
            label?.stringValue = path.isEmpty ? emptyText : path
            label?.toolTip = path.isEmpty ? nil : path
            label?.textColor = enabled ? .labelColor : .disabledControlTextColor
            buttons?.change.title = path.isEmpty ? "Choose…" : "Change…"
            buttons?.change.isEnabled = enabled
            buttons?.clear.isEnabled = enabled && !path.isEmpty
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

    @objc private func chooseStagingFolder() { actions.chooseStagingFolder() }

    /// Asks for a folder row's folder in a sheet. Only its path is stored, so nothing here
    /// reads the volume.
    @objc private func chooseFolder(_ button: NSButton) {
        guard let key = button.identifier?.rawValue, let window = view.window,
            case .folder(_, let message) = model.rows.first(where: { $0.key == key })?.control
        else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = message
        let current = model.text(key)
        if !current.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: current, isDirectory: true)
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            guard let self else { return }
            attempt { try model.setText(key, url.standardizedFileURL.path) }
        }
    }

    @objc private func clearFolder(_ button: NSButton) {
        guard let key = button.identifier?.rawValue else { return }
        attempt { try model.clear(key) }
    }

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

    /// Saves the well's color once it has stopped changing for `colorPauseSeconds`.
    @objc private func choseColor(_ well: NSColorWell) {
        guard let key = well.identifier?.rawValue,
            let color = well.color.usingColorSpace(.sRGB)
        else { return }
        let hex = HexColor(
            red: color.redComponent, green: color.greenComponent, blue: color.blueComponent,
            alpha: color.alphaComponent)
        colorGenerations[key, default: 0] += 1
        let mine = colorGenerations[key]
        Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(Self.colorPauseSeconds * 1_000_000_000))
            } catch {
                return
            }
            guard let self, self.colorGenerations[key] == mine, self.model.color(key) != hex else {
                return
            }
            self.attempt { try self.model.setColor(key, hex) }
        }
    }

    @objc private func defaultColor(_ button: NSButton) {
        guard let key = button.identifier?.rawValue else { return }
        // A color still waiting to be saved would put the color back after the null.
        colorGenerations[key, default: 0] += 1
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

    /// Saves a template row as it's typed, when the text parses; else says why under the field
    /// and saves nothing.
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
            let key = field.identifier?.rawValue, let problemLine = templateProblems[key]
        else { return }
        let problem = GeneralModel.templateProblem(field.stringValue)
        problemLine.stringValue = problem ?? ""
        problemLine.isHidden = problem == nil
        guard problem == nil else { return }
        attempt { try model.setText(key, field.stringValue) }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let key = field.identifier?.rawValue
        else { return }
        // Text that didn't parse is put back below, so its problem no longer applies.
        templateProblems[key]?.isHidden = true
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
