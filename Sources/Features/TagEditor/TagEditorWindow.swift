import AppKit
import Artwork
import Commands
import Discogs
import DisplayText
import Metadata
import Settings
import TagWriter
import UniformTypeIdentifiers
import WindowPlacement

/// An info window: tabs of fields as `TagEditorTab` lays them out, the art with Replace and
/// Remove, the file's format, and Undo Tag Edit, Cancel and Save. It opens at once, before its
/// files are read, laid out as it stays, saying so, and fills in the fields once `load` hands
/// it the tracks. It resizes, and keeps its frame (ADR 0160).
/// Fields where the tracks differ show "Mixed" until typed in, and a field typed differently
/// from what it showed has a dot by its label. It edits a `TagEditorModel` and hands back the
/// checked edit. Several can be open at once.
@MainActor
public final class TagEditorWindow: NSObject, NSTextFieldDelegate, NSTextViewDelegate,
    NSWindowDelegate
{
    /// The files Get Info was asked for, in the selection's order.
    public let paths: [String]
    /// Nil until the files are read.
    public private(set) var model: TagEditorModel?
    public let window: NSWindow
    /// Called with the edit when the user saves. The window stays open until `close()`.
    var saved: (TagEdit) -> Void = { _ in }
    /// Called once when the window closes, by Cancel, its close button or `close()`.
    var closed: () -> Void = {}
    /// Runs one of the registry's tag commands as its menu item does, for the window's Undo
    /// Tag Edit and art buttons.
    var run: (CommandID) -> Void = { _ in }
    /// Whether the registry enables a tag command now, which its buttons follow.
    var isEnabled: (CommandID) -> Bool = { _ in false }
    /// Called when what the commands' rules read may have changed: the files were read, the
    /// art changed, or the window became key.
    var commandsChanged: () -> Void = {}

    /// A field can show on more than one tab, as the title does on Info and Sorting.
    private(set) var fields: [TagEditField: [NSTextField]] = [:]
    private var areas: [TagEditField: NSTextView] = [:]
    /// Shows "Mixed" in an empty text area, which has no placeholder of its own.
    private var areaPlaceholders: [TagEditField: NSTextField] = [:]
    private var labels: [TagEditField: [NSTextField]] = [:]
    private let compilationBox = NSButton(
        checkboxWithTitle: TagEditField.compilation.title, target: nil, action: nil)
    let tabs = NSTabView()
    private let artView = NSImageView()
    private let largeArtView = NSImageView()
    private let artNote = NSTextField(labelWithString: "")
    private let artDetails = NSTextField(labelWithString: "")
    /// The buttons that run a registry command, each with its command.
    private(set) var commandButtons: [(id: CommandID, button: NSButton)] = []
    private var fileValues: [FileRow: NSTextField] = [:]
    /// The Extras tab's keys and values, a row each; a value is typed in as a field is.
    let extrasTable = NSTableView()
    /// The rows `extrasTable` shows, as the model last gave them.
    private(set) var extraRows: [ExtraRow] = []
    let addExtraButton = NSButton()
    let removeExtraButton = NSButton()
    /// Asks for the name of a key to add to Extras, then calls back with what was typed; not
    /// called when the user cancels.
    var askExtraKey: (@escaping (String) -> Void) -> Void = { _ in }
    /// The Discogs tab's release, or why it isn't shown.
    let discogsText = readOnlyText()
    /// The Discogs tab's release id, which edits `DiscogsKey.releaseID` in every file.
    let releaseIDField = NSTextField()
    private let openOnDiscogsButton = NSButton()
    /// The release the Discogs tab shows: the one typed, else the files'; nil for none.
    private(set) var discogsReleaseID: Int?
    /// Reads release `id` from the local catalog: nil when it doesn't have it, and
    /// `CatalogError.missing` with no catalog.
    var release: @MainActor (Int) async throws -> ReleaseDetail? = { _ in nil }
    /// Opens a page in the browser, for Open on Discogs.
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Spins in the buttons row while the files are read; it keeps its space once stopped.
    private let spinner = NSProgressIndicator()
    /// One line beside the buttons: "Reading tags…", then why some files can't be saved, or why
    /// Save failed.
    let problemLabel = NSTextField(labelWithString: "Reading tags…")
    let saveButton = NSButton(title: "Save", target: nil, action: nil)
    /// Whether the line shows why Save, or adding a key to Extras, failed, in place of its note.
    private var showsSaveError = false
    /// Says, as soon as such a field is edited, that saving keeps one of its several values.
    private let collapseLabel = NSTextField(wrappingLabelWithString: "")
    private var isClosed = false

    static let artPoints = 120.0
    static let largeArtPoints = 300.0
    /// The tab view's least height, which the tallest tab, Info, fits in. The window takes its
    /// size from the content before a tab's view is in the tab view, which sizes its views by
    /// their frames, so a tab taller than this would make the window grow as it shows.
    private static let tabsHeight = 470.0
    private static let numberWidth = 44.0
    private static let shortWidth = 80.0
    /// The tab last chosen, which the next window opens on.
    private static var lastTab = TagEditorTab.info
    /// The name its frame is kept by (ADR 0158); its title is its files'.
    static let frameName = "Get Info Window"

    init(paths: [String]) {
        precondition(!paths.isEmpty, "Get Info opens on at least one track")
        self.paths = paths
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 120),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
            defer: false)
        super.init()
        askExtraKey = { [weak self] in self?.askForExtraKey($0) }
        window.isReleasedWhenClosed = false
        window.title = heading
        window.delegate = self
        // The whole layout is made now, every tab there from the start, so nothing moves
        // when the fields fill in.
        window.contentView = makeContent()
        build(Self.lastTab)
        tabs.selectTabViewItem(withIdentifier: Self.lastTab.rawValue)
        // It opens the first time at its least size, which fits every tab's label.
        if let content = window.contentView {
            window.contentMinSize = content.fittingSize
            window.setContentSize(content.fittingSize)
        }
        showEditable()
    }

    /// The file's name, or how many tracks.
    private var heading: String {
        paths.count == 1 ? (paths[0] as NSString).lastPathComponent : "\(paths.count) tracks"
    }

    public var isLoaded: Bool { model != nil }

    /// Shows the window in front. One not yet on screen opens at the frame the info windows
    /// keep (ADR 0158), or, while `last` is open, cascaded from it at its size. It's laid out
    /// before it shows, so it shows at its final layout.
    func show(after last: NSWindow?) {
        if !window.isVisible {
            if let last {
                window.setContentSize(last.contentRect(forFrameRect: last.frame).size)
                let corner = NSPoint(x: last.frame.minX, y: last.frame.maxY)
                window.setFrameTopLeftPoint(window.cascadeTopLeft(from: corner))
            } else {
                window.keepsFrame(as: Self.frameName)
            }
            window.layoutIfNeeded()
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// Shows the fields for `model`. A second call, after the files were read again, keeps what
    /// the user typed and the art they chose, and shows the rest as the files hold them now.
    func load(_ model: TagEditorModel) {
        if var current = self.model {
            current.reread(model.tracks)
            self.model = current
            showValues()
            showDiscogs(current.shownReleaseIDs)
            return
        }
        self.model = model
        spinner.stopAnimation(nil)
        showNote(model.readOnlyNote ?? "", color: .secondaryLabelColor)
        showEditable()
        showValues()
        showDiscogs(model.shownReleaseIDs)
        focusFirstField()
    }

    /// The release ids the Discogs tab was last read for, so a reread that leaves them as
    /// they were reads nothing again.
    private var discogsShownIDs: [Int]?
    /// Counts the catalog reads, so one finishing after a later one started is dropped.
    private var discogsRead = 0

    /// Reads the first of `ids` into the Discogs tab; with none, the tab says how to give the
    /// files one. The tab is always there, so the tab bar doesn't change once the window shows.
    private func showDiscogs(_ ids: [Int]) {
        guard ids != discogsShownIDs else { return }
        discogsShownIDs = ids
        discogsRead += 1
        discogsReleaseID = ids.first
        openOnDiscogsButton.isEnabled = discogsReleaseID != nil
        guard let first = ids.first else {
            discogsText.string = noReleaseText
            return
        }
        discogsText.string = "Reading the Discogs catalog…"
        let release = self.release
        let mine = discogsRead
        Task { [weak self] in
            let read: Result<ReleaseDetail?, any Error>
            do {
                read = .success(try await release(first))
            } catch {
                read = .failure(error)
            }
            guard let self, mine == discogsRead else { return }
            discogsText.string = discogsTabText(read, releases: ids.count)
        }
    }

    private func tabItem(_ tab: TagEditorTab) -> NSTabViewItem? {
        tabs.tabViewItems.first { $0.identifier as? String == tab.rawValue }
    }

    /// The tabs the window has, in order.
    var shownTabs: [TagEditorTab] {
        tabs.tabViewItems.compactMap { ($0.identifier as? String).flatMap(TagEditorTab.init) }
    }

    private var builtTabs: Set<TagEditorTab> = []

    /// Makes `tab`'s fields the first time it's shown, filled with the model's values.
    private func build(_ tab: TagEditorTab) {
        guard !builtTabs.contains(tab), let item = tabItem(tab) else { return }
        builtTabs.insert(tab)
        item.view = tabView(tab)
        showEditable()
        showValues()
    }

    /// The tab shown.
    var shownTab: TagEditorTab? {
        (tabs.selectedTabViewItem?.identifier as? String).flatMap(TagEditorTab.init)
    }

    /// Shows the tab `step` places after the one shown, wrapping past either end, as Back and
    /// Forward do in an info window.
    func stepTab(_ step: Int) {
        let all = shownTabs
        let index = shownTab.flatMap { all.firstIndex(of: $0) } ?? 0
        let next = all[((index + step) % all.count + all.count) % all.count]
        tabs.selectTabViewItem(withIdentifier: next.rawValue)
    }

    func replaceArt(_ image: Data, mimeType: String) {
        model?.replaceArt(image, mimeType: mimeType)
        showArt()
        clearSaveError()
    }

    func removeArt() {
        model?.removeArt()
        showArt()
        clearSaveError()
    }

    func close() {
        window.close()
        // A window never put on screen doesn't send `windowWillClose`.
        windowClosed()
    }

    public func windowWillClose(_ notification: Notification) { windowClosed() }

    public func windowDidBecomeKey(_ notification: Notification) { commandsChanged() }

    private func windowClosed() {
        guard !isClosed else { return }
        isClosed = true
        closed()
    }

    // MARK: Layout

    private func headingLabel() -> NSTextField {
        let label = NSTextField(labelWithString: heading)
        label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        label.lineBreakMode = .byTruncatingMiddle
        return label
    }

    private func makeContent() -> NSView {
        let heading = headingLabel()
        setUpArtViews()
        // Each tab's fields are made when it's first shown, so the window opens on one tab's
        // worth of views.
        for tab in TagEditorTab.allCases {
            let item = NSTabViewItem(identifier: tab.rawValue)
            item.label = tab.title
            item.view = NSView()
            tabs.addTabViewItem(item)
        }
        // After the tabs are added, since adding the first selects it, which isn't a choice.
        tabs.delegate = self
        tabs.translatesAutoresizingMaskIntoConstraints = false
        // Every tab's label fits at the least width, so the tab bar never squeezes them.
        tabs.widthAnchor.constraint(greaterThanOrEqualToConstant: tabs.minimumSize.width)
            .isActive = true
        tabs.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.tabsHeight).isActive = true
        // The tabs take the height the window is given past its least.
        tabs.setContentHuggingPriority(.init(1), for: .vertical)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.startAnimation(nil)
        // One line, so a longer message doesn't make the row taller; the tooltip has it whole.
        problemLabel.textColor = .secondaryLabelColor
        problemLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        problemLabel.lineBreakMode = .byTruncatingTail
        problemLabel.setContentHuggingPriority(.init(1), for: .horizontal)
        problemLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        saveButton.target = self
        saveButton.action = #selector(saveClicked)
        saveButton.keyEquivalent = "\r"
        let undo = commandButton(.undoTagEdit, size: .regular)
        // The journal keeps one list of edits for every window (ADR 0020).
        undo.toolTip = "Undoes the last tag edit, wherever it was made"
        let buttons = NSStackView(views: [undo, spinner, problemLabel, cancel, saveButton])

        collapseLabel.textColor = .systemOrange
        collapseLabel.isHidden = true
        let stack = NSStackView(views: [heading, tabs, collapseLabel, buttons])
        stack.orientation = .vertical
        // The room a resize gives goes to the tabs, not between the rows.
        stack.distribution = .fill
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(
            top: DialogMargin.value, left: DialogMargin.value, bottom: DialogMargin.value,
            right: DialogMargin.value)
        for view in [heading, tabs, collapseLabel, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(
                equalTo: stack.widthAnchor, constant: -2 * DialogMargin.value
            ).isActive = true
        }
        return stack
    }

    /// A tab's view: its rows in a grid of a label column, a field column and, for a second
    /// field, a label and a short field at the right, pinned to the tab's top.
    private func tabView(_ tab: TagEditorTab) -> NSView {
        let content: NSView =
            switch tab {
            case .artwork: artworkView()
            case .file: fileView()
            case .lyrics: areaView(.lyrics)
            case .extras: extrasView()
            case .discogs: discogsView()
            default: grid(tab.rows)
            }
        let container = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        let inset = 16.0
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: inset),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(
                equalTo: container.trailingAnchor, constant: -inset),
            content.bottomAnchor.constraint(
                lessThanOrEqualTo: container.bottomAnchor, constant: -inset),
        ])
        if [.lyrics, .extras, .discogs].contains(tab) {
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -inset)
                .isActive = true
        }
        return container
    }

    private func grid(_ rows: [TagEditorRow]) -> NSGridView {
        let empty = NSGridCell.emptyContentView
        var cells: [[NSView]] = []
        var spans: [Int] = []
        var gaps: Set<Int> = []
        for row in rows {
            switch row {
            case .wide(let field):
                cells.append([label(field), self.field(field), empty, empty])
                spans.append(cells.count - 1)
            case .pair(let wide, let short):
                cells.append([
                    label(wide), field(wide), label(short),
                    field(short, minimumWidth: Self.shortWidth),
                ])
            case .numbers(let wide, let number, let total):
                let numbers = NSStackView(views: [
                    field(number, width: Self.numberWidth), label(total),
                    field(total, width: Self.numberWidth),
                ])
                cells.append([label(wide), field(wide), label(number), numbers])
            case .commentAndArt:
                artNote.textColor = .secondaryLabelColor
                artNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                let art = NSStackView(views: [artView, artNote, artButtons(size: .small)])
                art.orientation = .vertical
                art.alignment = .centerX
                art.spacing = 4
                let area = areaView(.comment)
                area.heightAnchor.constraint(equalToConstant: Self.artPoints + 48).isActive = true
                let row = NSStackView(views: [area, art])
                row.alignment = .top
                cells.append([label(.comment), row, empty, empty])
                spans.append(cells.count - 1)
            case .flag:
                compilationBox.allowsMixedState = true
                compilationBox.target = self
                compilationBox.action = #selector(compilationChanged)
                cells.append([empty, compilationBox, empty, empty])
                spans.append(cells.count - 1)
            case .area(let field):
                cells.append([label(field), areaView(field), empty, empty])
                spans.append(cells.count - 1)
            case .gap:
                gaps.insert(cells.count)
            }
        }
        let grid = NSGridView(views: cells)
        grid.rowSpacing = 6
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 2).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        // A short field takes the width of the number and its total below or above it.
        grid.column(at: 3).xPlacement = .fill
        for index in spans {
            grid.row(at: index).mergeCells(in: NSRange(location: 1, length: 3))
        }
        for index in gaps where index < grid.numberOfRows {
            grid.row(at: index).topPadding = 10
        }
        for index in 0..<grid.numberOfRows {
            grid.row(at: index).yPlacement = .center
        }
        if let comment = rows.firstIndex(of: .commentAndArt) {
            grid.row(at: comment).yPlacement = .top
        }
        // The labels and the number pairs keep their own widths, so the fields take the rest of
        // the tab, not the label column.
        for (column, merged) in [(0, false), (2, true), (3, true)] {
            let widths = (0..<grid.numberOfRows).compactMap { row -> CGFloat? in
                guard !(merged && spans.contains(row)) else { return nil }
                return grid.cell(atColumnIndex: column, rowIndex: row).contentView?.fittingSize
                    .width
            }
            grid.column(at: column).width = max(
                widths.max() ?? 0, column == 3 ? Self.shortWidth : 0)
        }
        return grid
    }

    private func label(_ field: TagEditField) -> NSTextField {
        let view = NSTextField(labelWithString: "")
        // A label shows whole; the fields give up the width.
        view.setContentCompressionResistancePriority(.required, for: .horizontal)
        view.setContentHuggingPriority(.required, for: .horizontal)
        labels[field, default: []].append(view)
        showLabel(view, field.title, edited: false)
        return view
    }

    /// The label with a dot before it when the field or key is edited. The dot is there, clear,
    /// otherwise, so the label doesn't move.
    private func showLabel(_ view: NSTextField, _ title: String, edited: Bool) {
        let text = NSMutableAttributedString(
            string: "● ",
            attributes: [
                .foregroundColor: edited ? NSColor.controlAccentColor : NSColor.clear,
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            ])
        text.append(
            NSAttributedString(
                string: title, attributes: [.font: NSFont.systemFont(ofSize: 0)]))
        view.attributedStringValue = text
    }

    private func field(
        _ field: TagEditField, width: Double? = nil, minimumWidth: Double = 160
    ) -> NSTextField {
        let view = NSTextField()
        view.delegate = self
        view.lineBreakMode = .byTruncatingTail
        view.cell?.usesSingleLineMode = true
        if field.numberProperty != nil { view.alignment = .right }
        if let width {
            view.widthAnchor.constraint(equalToConstant: width).isActive = true
        } else {
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: minimumWidth).isActive = true
        }
        fields[field, default: []].append(view)
        return view
    }

    /// A text area of several lines, which Return breaks and Tab leaves.
    private func areaView(_ field: TagEditField) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        let text = scroll.documentView as! NSTextView
        text.delegate = self
        text.isRichText = false
        text.allowsUndo = true
        text.font = .systemFont(ofSize: NSFont.systemFontSize)
        text.textContainerInset = NSSize(width: 2, height: 4)
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        let placeholder = NSTextField(labelWithString: mixedPlaceholder)
        placeholder.textColor = .placeholderTextColor
        placeholder.frame.origin = NSPoint(x: 6, y: 4)
        placeholder.sizeToFit()
        placeholder.isHidden = true
        text.addSubview(placeholder)
        areas[field] = text
        areaPlaceholders[field] = placeholder
        scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        return scroll
    }

    /// Replace and Remove, titled in full on the Artwork tab, and short beside the small art
    /// on the Info tab, where the full titles don't fit under it.
    private func artButtons(size: NSControl.ControlSize) -> NSStackView {
        let replace = commandButton(.replaceArtwork, size: size)
        let remove = commandButton(.removeArtwork, size: size)
        if size == .small {
            replace.title = "Replace…"
            remove.title = "Remove"
        }
        return NSStackView(views: [replace, remove])
    }

    /// A button that runs `id`, titled as its menu item.
    private func commandButton(_ id: CommandID, size: NSControl.ControlSize) -> NSButton {
        let button = NSButton(
            title: AppCommands.title(of: id), target: self, action: #selector(commandClicked))
        button.controlSize = size
        button.font = .systemFont(ofSize: NSFont.systemFontSize(for: size))
        button.isEnabled = false
        commandButtons.append((id, button))
        return button
    }

    /// Enables each command button as the registry's rule for its command says now.
    func refreshCommands() {
        for (id, button) in commandButtons { button.isEnabled = isEnabled(id) }
    }

    private func setUpArtViews() {
        for (view, points) in [(artView, Self.artPoints), (largeArtView, Self.largeArtPoints)] {
            view.imageScaling = .scaleProportionallyUpOrDown
            view.imageFrameStyle = .grayBezel
            view.widthAnchor.constraint(equalToConstant: points).isActive = true
            view.heightAnchor.constraint(equalToConstant: points).isActive = true
        }
    }

    private func artworkView() -> NSView {
        artDetails.textColor = .secondaryLabelColor
        artDetails.isSelectable = true
        let stack = NSStackView(views: [largeArtView, artDetails, artButtons(size: .regular)])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        return stack
    }

    /// The release id over the release's text, and Open on Discogs.
    private func discogsView() -> NSView {
        releaseIDField.delegate = self
        releaseIDField.cell?.usesSingleLineMode = true
        releaseIDField.alignment = .right
        releaseIDField.widthAnchor.constraint(equalToConstant: Self.shortWidth * 1.5).isActive =
            true
        let label = NSTextField(labelWithString: DiscogsField.releaseID.title)
        let id = NSStackView(views: [label, releaseIDField])
        let scroll = readOnlyTextView(discogsText)
        openOnDiscogsButton.title = openOnDiscogsTitle
        openOnDiscogsButton.bezelStyle = .rounded
        openOnDiscogsButton.target = self
        openOnDiscogsButton.action = #selector(openOnDiscogs)
        let stack = NSStackView(views: [id, scroll, openOnDiscogsButton])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 10
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        id.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
        return stack
    }

    /// The Extras table, a column of keys and one of values, over + and − buttons.
    private func extrasView() -> NSView {
        for (id, title, width) in [
            (Self.extraKeyColumn, "Key", 220.0), (Self.extraValueColumn, "Value", 360.0),
        ] {
            let column = NSTableColumn(identifier: id)
            column.title = title
            column.width = width
            extrasTable.addTableColumn(column)
        }
        extrasTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        extrasTable.allowsMultipleSelection = true
        extrasTable.usesAlternatingRowBackgroundColors = true
        extrasTable.dataSource = self
        extrasTable.delegate = self
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.documentView = extrasTable
        for (button, image, action) in [
            (addExtraButton, NSImage.addTemplateName, #selector(addExtraClicked)),
            (removeExtraButton, NSImage.removeTemplateName, #selector(removeExtrasClicked)),
        ] {
            button.bezelStyle = .smallSquare
            button.image = NSImage(named: image)
            button.target = self
            button.action = action
        }
        addExtraButton.toolTip = "Add a key to every file"
        removeExtraButton.toolTip = "Remove the selected keys from every file"
        let stack = NSStackView(views: [
            scroll, NSStackView(views: [addExtraButton, removeExtraButton]),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        showExtrasEditable()
        return stack
    }

    static let extraKeyColumn = NSUserInterfaceItemIdentifier("key")
    static let extraValueColumn = NSUserInterfaceItemIdentifier("value")

    /// The sheet + shows: a field for the new key's name.
    private func askForExtraKey(_ answer: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Add a Key to Extras"
        alert.informativeText =
            "Every file gets the key once you type its value and save. A field's name can't be"
            + " used: it would read back as that field."
        let name = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        name.placeholderString = "Key name"
        alert.accessoryView = name
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = name
        alert.beginSheetModal(for: window) {
            if $0 == .alertFirstButtonReturn { answer(name.stringValue) }
        }
    }

    @objc private func addExtraClicked() { askExtraKey { [weak self] in self?.addExtra($0) } }

    /// Adds key `name` to Extras and starts typing its value, or says on the window's line
    /// why it can't be added.
    func addExtra(_ name: String) {
        guard var current = model else { return }
        let problem = current.addExtra(name)
        model = current
        if let problem {
            showNote(problem, color: .systemRed)
            showsSaveError = true
            NSSound.beep()
            return
        }
        showExtras()
        showEdited()
        let key = name.uppercased()
        guard let row = extraRows.firstIndex(where: { $0.key == key }) else { return }
        extrasTable.selectRowIndexes([row], byExtendingSelection: false)
        extrasTable.scrollRowToVisible(row)
        extrasTable.editColumn(1, row: row, with: nil, select: true)
    }

    /// Takes the selected keys out of Extras, and out of every file when saved.
    @objc func removeExtrasClicked() {
        guard model?.canSave == true else { return }
        window.endEditing(for: nil)
        for row in extrasTable.selectedRowIndexes where row < extraRows.count {
            model?.deleteExtra(extraRows[row].key)
        }
        extrasTable.deselectAll(nil)
        showExtras()
        showEdited()
    }

    /// + while any file can be saved, and − while a key is selected too.
    private func showExtrasEditable() {
        let editable = model?.canSave == true
        addExtraButton.isEnabled = editable
        removeExtraButton.isEnabled = editable && !extrasTable.selectedRowIndexes.isEmpty
    }

    @objc func openOnDiscogs() {
        guard let discogsReleaseID else { return }
        openURL(discogsPage(discogsReleaseID))
    }

    /// `text`, made by `readOnlyText`, in a scroll view.
    private func readOnlyTextView(_ text: NSTextView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.documentView = text
        return scroll
    }

    private func fileView() -> NSView {
        let rows = FileRow.allCases.map { row -> [NSView] in
            let title = NSTextField(labelWithString: row.title)
            title.textColor = .secondaryLabelColor
            let value = NSTextField(labelWithString: "")
            value.isSelectable = true
            value.lineBreakMode = .byTruncatingMiddle
            value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            fileValues[row] = value
            return [title, value]
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 6
        grid.column(at: 0).xPlacement = .trailing
        return grid
    }

    private func focusFirstField() {
        let tab = TagEditorTab(rawValue: tabs.selectedTabViewItem?.identifier as? String ?? "")
        guard let first = tab?.rows.flatMap(\.fields).first else { return }
        if let area = areas[first] {
            window.makeFirstResponder(area)
        } else if let view = fields[first]?.last {
            window.makeFirstResponder(view)
        }
    }

    // MARK: Values

    /// Lets the fields, the art buttons and Save be used once the files are read, if any of
    /// them can be written.
    private func showEditable() {
        let editable = model?.canSave == true
        for view in fields.values.joined() { view.isEditable = editable }
        for view in areas.values { view.isEditable = editable }
        compilationBox.isEnabled = editable
        releaseIDField.isEditable = editable
        saveButton.isEnabled = editable
        showExtrasEditable()
        commandsChanged()
    }

    /// Puts the model's values in the fields, and the art. A field typed in keeps what was
    /// typed, which a tab made since shows too.
    private func showValues() {
        guard let model else { return }
        for (field, views) in fields {
            for view in views {
                // Setting the same text would move the cursor of the field being typed in.
                if view.stringValue != model.text(field) { view.stringValue = model.text(field) }
                view.placeholderString = model.isMixed(field) ? mixedPlaceholder : nil
            }
        }
        for (field, view) in areas where view.string != model.text(field) {
            view.string = model.text(field)
        }
        showAreaPlaceholders()
        if releaseIDField.stringValue != model.releaseIDText {
            releaseIDField.stringValue = model.releaseIDText
        }
        releaseIDField.placeholderString = model.isReleaseIDMixed ? mixedPlaceholder : nil
        if !model.isTyped(.compilation) {
            compilationBox.state =
                model.isMixed(.compilation)
                ? .mixed : model.text(.compilation) == "1" ? .on : .off
        }
        showArt()
        showFile()
        showExtras()
        showEdited()
    }

    /// The Extras tab: a row a key, its value, or "Mixed" where the tracks differ, and a dot
    /// by an edited key. Only a change reloads the table, so a value being typed keeps its
    /// cursor.
    private func showExtras() {
        guard let model, model.extras != extraRows else { return }
        extraRows = model.extras
        extrasTable.reloadData()
        showExtrasEditable()
    }

    /// A value typed in Extras, which goes to every track.
    private func extraChanged(_ view: NSTextField, row: Int) {
        guard model != nil, extraRows.indices.contains(row) else { return }
        model?.setExtra(extraRows[row].key, view.stringValue)
        view.placeholderString = nil
        extraRows = model?.extras ?? []
        extrasTable.reloadData(forRowIndexes: [row], columnIndexes: [0])
        showEdited()
    }

    /// A release id typed on the Discogs tab: it goes to every file as Extras' key does, and
    /// the tab reads that release.
    private func releaseIDChanged() {
        guard model != nil else { return }
        model?.setExtra(DiscogsKey.releaseID, releaseIDField.stringValue)
        releaseIDField.placeholderString = nil
        showExtras()
        showEdited()
        if let model { showDiscogs(model.shownReleaseIDs) }
    }

    private func showAreaPlaceholders() {
        guard let model else { return }
        for (field, placeholder) in areaPlaceholders {
            placeholder.isHidden = !(model.isMixed(field) && areas[field]?.string.isEmpty == true)
        }
    }

    private func showEdited() {
        guard let model else { return }
        clearSaveError()
        for (field, views) in labels {
            for view in views { showLabel(view, field.title, edited: model.isEdited(field)) }
        }
        let note = model.collapseNote
        collapseLabel.stringValue = note ?? ""
        collapseLabel.isHidden = note == nil
    }

    private func showArt() {
        guard let model else { return }
        let art = model.shownArt
        // A Retina screen draws two pixels a point.
        for (view, points) in [(artView, Self.artPoints), (largeArtView, Self.largeArtPoints)] {
            view.image =
                art
                .flatMap { thumbnail(of: $0, maxPixelSize: Int(points) * 2) }
                .map { NSImage(cgImage: $0, size: .zero) }
        }
        artNote.stringValue =
            switch model.art {
            case .replaced: "New artwork"
            case .removed: "Artwork removed"
            case .unchanged:
                model.isArtMixed ? mixedPlaceholder : art == nil ? "No artwork" : ""
            }
        artDetails.stringValue =
            art.map(imageDescription)
            ?? (artNote.stringValue.isEmpty ? "No artwork" : artNote.stringValue)
        commandsChanged()
    }

    private func showFile() {
        guard let model else { return }
        for row in FileRow.allCases {
            let values = Set(model.tracks.map { row.text($0) })
            fileValues[row]?.stringValue =
                row == .size
                ? fileSizeText(model.tracks.compactMap(\.file?.sizeBytes).reduce(0, +))
                : values.count == 1 ? values.first! : mixedPlaceholder
        }
    }

    // MARK: Editing

    public func controlTextDidChange(_ notification: Notification) {
        if let view = notification.object as? NSTextField, view.isDescendant(of: extrasTable) {
            return extraChanged(view, row: extrasTable.row(for: view))
        }
        if notification.object as? NSTextField === releaseIDField {
            return releaseIDChanged()
        }
        guard let view = notification.object as? NSTextField,
            let field = fields.first(where: { $0.value.contains { $0 === view } })?.key
        else { return }
        model?.set(field, view.stringValue)
        // The same field on another tab shows what was typed.
        for other in fields[field] ?? [] where other !== view {
            other.stringValue = view.stringValue
            other.placeholderString = nil
        }
        showEdited()
    }

    public func textDidChange(_ notification: Notification) {
        guard let view = notification.object as? NSTextView,
            let field = areas.first(where: { $0.value === view })?.key
        else { return }
        model?.set(field, view.string)
        showAreaPlaceholders()
        showEdited()
    }

    @objc private func compilationChanged() {
        // The mixed state is only where it starts; a click sets the flag for every track.
        if compilationBox.state == .mixed { compilationBox.state = .on }
        model?.set(.compilation, compilationBox.state == .on ? "1" : "")
        showEdited()
    }

    /// Puts back the line's note about files that can't be saved, which a Save error replaced,
    /// once the user changes something.
    private func clearSaveError() {
        guard showsSaveError else { return }
        showsSaveError = false
        showNote(model?.readOnlyNote ?? "", color: .secondaryLabelColor)
    }

    private func showNote(_ text: String, color: NSColor) {
        problemLabel.stringValue = text
        problemLabel.toolTip = text.isEmpty ? nil : text
        problemLabel.textColor = color
    }

    @objc private func commandClicked(_ sender: NSButton) {
        guard let id = commandButtons.first(where: { $0.button === sender })?.id else { return }
        run(id)
    }
    @objc private func cancelClicked() { close() }

    @objc private func saveClicked() {
        guard let model else { return }
        do {
            let edit = try model.edit()
            clearSaveError()
            saved(edit)
        } catch {
            showNote(error.description, color: .systemRed)
            showsSaveError = true
            NSSound.beep()
        }
    }
}

extension TagEditorWindow: NSTabViewDelegate {
    public func tabView(_ tabView: NSTabView, willSelect item: NSTabViewItem?) {
        guard let id = item?.identifier as? String, let tab = TagEditorTab(rawValue: id) else {
            return
        }
        build(tab)
    }

    public func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        guard let id = item?.identifier as? String, let tab = TagEditorTab(rawValue: id) else {
            return
        }
        Self.lastTab = tab
    }
}

extension TagEditorWindow: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int { extraRows.count }

    /// A key, with a dot when edited, or its value, which can be typed in while any file can
    /// be saved. A mixed value shows "Mixed" until typed in.
    public func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int)
        -> NSView?
    {
        guard let column, row < extraRows.count else { return nil }
        let extra = extraRows[row]
        let view = NSTextField()
        view.isBordered = false
        view.drawsBackground = false
        view.lineBreakMode = .byTruncatingTail
        view.cell?.usesSingleLineMode = true
        if column.identifier == Self.extraKeyColumn {
            view.isEditable = false
            view.isSelectable = true
            showLabel(view, extra.key, edited: extra.isEdited)
        } else {
            view.isEditable = model?.canSave == true
            view.stringValue = extra.value ?? ""
            view.placeholderString = extra.value == nil ? mixedPlaceholder : nil
            view.delegate = self
        }
        return view
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        showExtrasEditable()
    }
}

/// A text view to select and copy from but not edit, which grows down with its text.
@MainActor
private func readOnlyText() -> NSTextView {
    let text = NSTextView()
    text.isEditable = false
    text.isSelectable = true
    text.isRichText = false
    text.textContainerInset = NSSize(width: 2, height: 4)
    text.autoresizingMask = .width
    text.isVerticallyResizable = true
    text.textContainer?.widthTracksTextView = true
    return text
}

/// "JPEG, 700 × 700, 126 KB": the image's type, pixels and size.
private func imageDescription(_ data: Data) -> String {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
        return fileSizeText(data.count)
    }
    var parts: [String] = []
    if let type = CGImageSourceGetType(source).flatMap({ UTType($0 as String) }) {
        parts.append(type.preferredFilenameExtension?.uppercased() ?? type.identifier)
    }
    if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
        let width = properties[kCGImagePropertyPixelWidth] as? Int,
        let height = properties[kCGImagePropertyPixelHeight] as? Int
    {
        parts.append("\(width) × \(height)")
    }
    parts.append(fileSizeText(data.count))
    return parts.joined(separator: ", ")
}
