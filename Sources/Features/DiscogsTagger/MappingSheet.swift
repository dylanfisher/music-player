import AppKit
import Settings
import UniformTypeIdentifiers

/// Field Mapping… (51.10): every Discogs field, release-level then track-level, with its mode,
/// its tags, the join between its values and a template; a preset or a saved mapping to start
/// from, and Save As to keep this one by name; Import…, Paste and Export… for the mapping as
/// JSON. OK saves it as the mapping in use. A key spelled per format or numbered is shown, and
/// edited in the config file. Under the fields, Artwork says whether the release's cover is
/// written, a setting of its own beside the mapping (ADR 0140), which needs a Discogs token.
@MainActor
final class MappingSheet: NSWindowController, TaggerSheet, NSTableViewDataSource,
    NSTableViewDelegate, NSTextFieldDelegate
{
    static let fields =
        DiscogsField.allCases.filter { $0.level == .release }
        + DiscogsField.allCases.filter { $0.level == .track }

    private(set) var draft: MappingDraft
    let presets = NSPopUpButton()
    let table = NSTableView()
    static let layoutKind = TaggerSheetKind.fieldMapping
    let nameField = NSTextField()
    let problemLabel = NSTextField(labelWithString: "")
    let okButton = NSButton(title: "OK", target: nil, action: nil)
    /// Takes the saved mapping chosen in Start from out of the list; off for a preset.
    let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    /// Where Paste reads from; tests use a pasteboard of their own.
    var pasteboard = NSPasteboard.general
    /// The template help while it shows.
    private var help: NSPopover?
    /// The mapping and saved ones on OK; nil for Cancel.
    private(set) var result: MappingDraft?
    /// The artwork mode shown, which OK saves with the mapping.
    private(set) var artwork: DiscogsArtworkMode
    let artworkPopUp = NSPopUpButton()
    let artworkNote = NSTextField(labelWithString: "")
    static let artworkTitle = "Cover Art"
    static let needsTokenNote = "Needs a Discogs token in config.json"

    init(draft: MappingDraft, artwork: DiscogsArtworkMode, hasToken: Bool) {
        self.draft = draft
        self.artwork = artwork
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 700, height: 360)
        super.init(window: window)
        build(in: window)
        artworkPopUp.addItems(withTitles: DiscogsArtworkMode.allCases.map(\.title))
        artworkPopUp.selectItem(at: DiscogsArtworkMode.allCases.firstIndex(of: artwork)!)
        artworkPopUp.target = self
        artworkPopUp.action = #selector(artworkChosen)
        artworkPopUp.isEnabled = hasToken
        artworkNote.stringValue =
            hasToken
            ? "The release's primary image, written as each file's cover" : Self.needsTokenNote
        artworkNote.textColor = .secondaryLabelColor
        confirmReplace = { [weak self] name, answer in self?.askToReplace(name, answer) }
        refused = { [weak self] message, detail in self?.showRefusal(message, detail) }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    private func build(in window: NSWindow) {
        presets.target = self
        presets.action = #selector(presetChosen)
        nameField.placeholderString = "Mapping Name"
        nameField.widthAnchor.constraint(equalToConstant: 160).isActive = true
        let save = NSButton(title: "Save As", target: self, action: #selector(saveAs))
        removeButton.target = self
        removeButton.action = #selector(removeSaved)
        removeButton.toolTip = "Removes the saved mapping chosen in Start from; OK keeps it removed"
        let top = NSStackView(views: [
            NSTextField(labelWithString: "Start from:"), presets, removeButton, NSView(),
            nameField, save,
        ])
        let scroll = taggerTable(
            table,
            [(.discogsField, 170), (.mode, 130), (.targets, 260), (.join, 60), (.template, 200)],
            source: self)
        table.rowHeight = 24
        problemLabel.textColor = .systemRed
        problemLabel.lineBreakMode = .byTruncatingTail
        problemLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        okButton.target = self
        okButton.action = #selector(ok)
        okButton.keyEquivalent = "\r"
        let file = [
            NSButton(title: "Import…", target: self, action: #selector(chooseImport)),
            NSButton(title: "Paste", target: self, action: #selector(paste)),
            NSButton(title: "Export…", target: self, action: #selector(chooseExport)),
        ]
        file[0].toolTip = "Shows a mapping from a JSON file, unsaved"
        file[1].toolTip = "Shows the mapping copied as JSON, unsaved"
        file[2].toolTip = "Writes the mapping shown as JSON, as the config file holds it"
        let buttons = NSStackView(
            views: file + [problemLabel, NSView(), cancel, okButton])
        let art = NSStackView(views: [
            NSTextField(labelWithString: "\(Self.artworkTitle):"), artworkPopUp, artworkNote,
        ])
        let page = NSStackView(views: [top, scroll, art, buttons])
        page.orientation = .vertical
        page.alignment = .leading
        page.spacing = 10
        page.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        for view in [top, scroll, art, buttons] {
            view.widthAnchor.constraint(equalTo: page.widthAnchor, constant: -32).isActive = true
        }
        window.contentView = page
    }

    /// Shows the draft: the presets with the one it is checked, each rule, and its problem.
    func refresh() {
        presets.removeAllItems()
        presets.addItems(withTitles: draft.choices.map(\.name))
        if let name = draft.chosenName {
            presets.selectItem(withTitle: name)
        } else {
            presets.addItem(withTitle: "Edited")
            presets.selectItem(withTitle: "Edited")
        }
        removeButton.isEnabled = draft.chosenName.map(draft.isSaved) ?? false
        table.reloadData()
        showProblem()
    }

    /// Shows why the mapping can't be used, or else what Save As did.
    private func showProblem() {
        let problem = draft.problem
        problemLabel.stringValue = problem ?? draft.note ?? ""
        problemLabel.textColor = problem == nil ? .secondaryLabelColor : .systemRed
        problemLabel.toolTip = problem
        okButton.isEnabled = problem == nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int { Self.fields.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        let field = Self.fields[row]
        let rule = draft.mapping[field]
        switch tableColumn.flatMap({ TaggerColumn(rawValue: $0.identifier.rawValue) }) {
        case .discogsField?:
            return NSTextField(labelWithString: field.title)
        case .mode?:
            let popUp = NSPopUpButton()
            popUp.controlSize = .small
            popUp.addItems(withTitles: DiscogsFieldRule.Mode.shown.map(\.title))
            popUp.selectItem(at: DiscogsFieldRule.Mode.shown.firstIndex(of: rule.mode)!)
            popUp.tag = row
            popUp.target = self
            popUp.action = #selector(modeChosen)
            return popUp
        case let column?:
            let text: String
            let editable: Bool
            switch column {
            case .targets:
                (text, editable) = (draft.targetsText(field), draft.targetsEditable(field))
            case .join: (text, editable) = (rule.format.join ?? "", true)
            default: (text, editable) = (rule.format.template ?? "", true)
            }
            let cell = NSTextField(string: text)
            cell.isEditable = editable
            cell.isBordered = editable
            cell.drawsBackground = editable
            cell.controlSize = .small
            cell.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            cell.identifier = column.identifier
            cell.tag = row
            cell.delegate = self
            cell.toolTip = editable ? nil : "Edited in the config file"
            guard column == .template else { return cell }
            let help = NSButton(title: "", target: self, action: #selector(showTemplateHelp))
            help.bezelStyle = .helpButton
            help.controlSize = .small
            help.toolTip = "What a template can hold"
            let row = NSStackView(views: [cell, help])
            row.spacing = 4
            return row
        case nil:
            return nil
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let cell = notification.object as? NSTextField, cell !== nameField else { return }
        guard let column = cell.identifier.flatMap({ TaggerColumn(rawValue: $0.rawValue) })
        else { return }
        set(cell.stringValue, in: column, row: cell.tag)
    }

    /// Sets the text column `column` of the rule on `row`.
    func set(_ text: String, in column: TaggerColumn, row: Int) {
        let field = Self.fields[row]
        switch column {
        case .targets: draft.setTargets(text, for: field)
        case .join: draft.mapping[field].setJoin(text)
        case .template: draft.mapping[field].setTemplate(text)
        default: return
        }
        refresh()
    }

    @objc private func modeChosen(_ sender: NSPopUpButton) {
        draft.mapping[Self.fields[sender.tag]].mode =
            DiscogsFieldRule.Mode.shown[sender.indexOfSelectedItem]
        refresh()
    }

    @objc private func presetChosen() {
        guard let name = presets.titleOfSelectedItem else { return }
        draft.use(name)
        refresh()
    }

    /// Removes the saved mapping Start from shows, from the draft: Cancel puts it back.
    @objc func removeSaved() {
        guard let name = draft.chosenName, draft.isSaved(name) else { return NSSound.beep() }
        draft.remove(name)
        refresh()
    }

    /// Asks whether to replace the saved mapping of the name given, then calls back with the
    /// answer; tests answer in its place.
    var confirmReplace: (String, @escaping (Bool) -> Void) -> Void = { _, answer in answer(false) }

    /// Saves the draft by the name typed, asking first when that replaces a saved mapping.
    @objc func saveAs() {
        let name = nameField.stringValue
        guard draft.replaces(name) else { return save(as: name) }
        confirmReplace(name.trimmingCharacters(in: .whitespaces)) { [weak self] yes in
            if yes { self?.save(as: name) }
        }
    }

    private func save(as name: String) {
        if let problem = draft.save(as: name) {
            problemLabel.stringValue = problem
            problemLabel.textColor = .systemRed
            return NSSound.beep()
        }
        refresh()
    }

    /// Asks for a JSON file of a mapping and shows it.
    @objc private func chooseImport() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Choose a field mapping exported as JSON. It's shown unsaved."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.importFile(at: url)
        }
    }

    /// Shows the mapping in the file at `url`, or says why it can't, changing nothing.
    func importFile(at url: URL) {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            return refused("The file couldn't be read", "\(error)")
        }
        load(text, from: "Imported “\(url.lastPathComponent)”")
    }

    /// Shows the mapping copied as JSON text.
    @objc func paste() {
        guard let text = pasteboard.string(forType: .string) else {
            return refused("The clipboard holds no text", "Copy a field mapping as JSON first.")
        }
        load(text, from: "Pasted")
    }

    private func load(_ text: String, from source: String) {
        // Ending the edit in a field commits its text first, so it can't land on what loads.
        window?.makeFirstResponder(nil)
        if let problem = draft.load(text, from: source) {
            return refused("That isn't a field mapping the config file takes", problem)
        }
        refresh()
    }

    /// Asks where to write the mapping shown as JSON, and writes it there.
    @objc private func chooseExport() {
        guard let window else { return }
        window.makeFirstResponder(nil)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = draft.chosenName ?? "Field Mapping"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.export(to: url)
        }
    }

    func export(to url: URL) {
        do {
            try Data(draft.exported.utf8).write(to: url, options: .atomic)
        } catch {
            refused("The mapping couldn't be exported", "\(error)")
        }
    }

    /// Says why an import, a paste or an export didn't happen; tests hear it in its place.
    var refused: (String, String) -> Void = { _, _ in }

    private func showRefusal(_ message: String, _ detail: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.beginSheetModal(for: window)
    }

    /// The question Save As asks over the sheet before it replaces a saved mapping.
    private func askToReplace(_ name: String, _ answer: @escaping (Bool) -> Void) {
        guard let window else { return answer(false) }
        let alert = NSAlert()
        alert.messageText = "Replace the mapping “\(name)”?"
        alert.informativeText =
            "A saved mapping has this name. Replace puts the mapping shown in its place."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { answer($0 == .alertFirstButtonReturn) }
    }

    /// The template help, beside the template field of the button's row.
    @objc private func showTemplateHelp(_ sender: NSButton) {
        let popover = TemplateHelp.popover()
        help = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxX)
    }

    @objc private func cancel() { endSheet() }

    @objc private func artworkChosen() {
        artwork = DiscogsArtworkMode.allCases[artworkPopUp.indexOfSelectedItem]
    }

    @objc private func ok() {

        // Ending the edit in a field commits its text to the draft, so check it after.
        window?.makeFirstResponder(nil)
        guard draft.problem == nil else { return NSSound.beep() }
        result = draft
        endSheet()
    }
}
