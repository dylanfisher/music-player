import AppKit
import Artwork
import DisplayText
import Metadata
import TagWriter
import UniformTypeIdentifiers

/// An info window: tabs of fields as `TagEditorTab` lays them out, the art with Replace and
/// Remove, the file's format, and Cancel and Save. It opens at once, before its files are read,
/// at the size it keeps, saying so, and fills in the fields once `load` hands it the tracks. Fields where the tracks
/// differ show "Mixed" until typed in, and a field typed differently from what it showed has a
/// dot by its label. It edits a `TagEditorModel` and hands back the checked edit. Several can
/// be open at once.
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
    /// Called with the window's top left corner when the user moves it.
    var moved: (NSPoint) -> Void = { _ in }
    /// The art buttons, which run the registry's Replace Artwork… and Remove Artwork.
    var replaceArtwork: () -> Void = {}
    var removeArtwork: () -> Void = {}

    /// A field can show on more than one tab, as the title does on Info and Sorting.
    private(set) var fields: [TagEditField: [NSTextField]] = [:]
    private var areas: [TagEditField: NSTextView] = [:]
    /// Shows "Mixed" in an empty text area, which has no placeholder of its own.
    private var areaPlaceholders: [TagEditField: NSTextField] = [:]
    private var labels: [TagEditField: [NSTextField]] = [:]
    private let compilationBox = NSButton(
        checkboxWithTitle: TagEditField.compilation.title, target: nil, action: nil)
    private let tabs = NSTabView()
    private let artView = NSImageView()
    private let largeArtView = NSImageView()
    private let artNote = NSTextField(labelWithString: "")
    private let artDetails = NSTextField(labelWithString: "")
    private var replaceButtons: [NSButton] = []
    private var removeButtons: [NSButton] = []
    private var fileValues: [FileRow: NSTextField] = [:]
    /// Spins in the buttons row while the files are read; it keeps its space once stopped.
    private let spinner = NSProgressIndicator()
    /// One line beside the buttons: "Reading tags…", then why some files can't be saved, or why
    /// Save failed.
    let problemLabel = NSTextField(labelWithString: "Reading tags…")
    let saveButton = NSButton(title: "Save", target: nil, action: nil)
    /// Says, as soon as such a field is edited, that saving keeps one of its several values.
    private let collapseLabel = NSTextField(wrappingLabelWithString: "")
    private var isClosed = false
    /// The top left corner the window was last put at or moved to, so a resize that keeps the
    /// corner isn't reported as a move.
    private var placedAt: NSPoint?

    static let width = 660.0
    static let artPoints = 120.0
    static let largeArtPoints = 300.0
    /// The tab view's height, which the tallest tab fills.
    private static let tabsHeight = 440.0
    private static let numberWidth = 44.0
    private static let shortWidth = 80.0
    /// The tab last chosen, which the next window opens on.
    private static var lastTab = TagEditorTab.info
    /// How far from the main window's top left corner a window opens with no place saved.
    private static let parentOffset = 40.0
    /// How many steps down and to the right a window goes, at most, past windows already open
    /// where it would open.
    private static let cascadeSteps = 20

    init(paths: [String]) {
        precondition(!paths.isEmpty, "Get Info opens on at least one track")
        self.paths = paths
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 120),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.title = heading
        window.delegate = self
        // The whole layout is made now, at the size it keeps, so nothing moves when the
        // fields fill in.
        window.contentView = makeContent()
        if let content = window.contentView { window.setContentSize(content.fittingSize) }
        build(Self.lastTab)
        tabs.selectTabViewItem(withIdentifier: Self.lastTab.rawValue)
        showEditable()
    }

    /// The file's name, or how many tracks.
    private var heading: String {
        paths.count == 1 ? (paths[0] as NSString).lastPathComponent : "\(paths.count) tracks"
    }

    public var isLoaded: Bool { model != nil }

    /// The window's top left corner, as `moved` reports it.
    var corner: NSPoint { NSPoint(x: window.frame.minX, y: window.frame.maxY) }

    /// Shows the window in front. One not yet on screen opens with its top left corner at
    /// `place`, where the user last moved an info window, or else near `parent`'s top left; a
    /// step down and to the right for each window in `taken` already at that corner.
    func show(beside parent: NSWindow, at place: NSPoint?, avoiding taken: [NSPoint]) {
        if !window.isVisible {
            let start = Self.start(
                place: place, parent: parent.frame, screens: NSScreen.screens.map(\.frame))
            var next = window.cascadeTopLeft(from: start)
            for _ in 0..<Self.cascadeSteps where taken.contains(corner) {
                next = window.cascadeTopLeft(from: next)
            }
            placedAt = corner
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// `place` while it's on one of `screens`, which a screen unplugged since may not be;
    /// otherwise a little inside `parent`'s top left corner.
    static func start(place: NSPoint?, parent: NSRect, screens: [NSRect]) -> NSPoint {
        if let place,
            screens.contains(where: {
                ($0.minX..<$0.maxX).contains(place.x) && $0.minY < place.y && place.y <= $0.maxY
            })
        {
            return place
        }
        return NSPoint(x: parent.minX + parentOffset, y: parent.maxY - parentOffset)
    }

    /// Shows the fields for `model`. A second call, after the files were read again, keeps what
    /// the user typed and the art they chose, and shows the rest as the files hold them now.
    func load(_ model: TagEditorModel) {
        if var current = self.model {
            current.reread(model.tracks)
            self.model = current
            showValues()
            return
        }
        self.model = model
        spinner.stopAnimation(nil)
        showNote(model.readOnlyNote ?? "", color: .secondaryLabelColor)
        showEditable()
        showValues()
        focusFirstField()
    }

    private var builtTabs: Set<TagEditorTab> = []

    /// Makes `tab`'s fields the first time it's shown, filled with the model's values.
    private func build(_ tab: TagEditorTab) {
        guard !builtTabs.contains(tab),
            let item = tabs.tabViewItems.first(where: { $0.identifier as? String == tab.rawValue })
        else { return }
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
        let all = TagEditorTab.allCases
        let index = shownTab.flatMap { all.firstIndex(of: $0) } ?? 0
        let next = all[((index + step) % all.count + all.count) % all.count]
        tabs.selectTabViewItem(withIdentifier: next.rawValue)
    }

    func replaceArt(_ image: Data, mimeType: String) {
        model?.replaceArt(image, mimeType: mimeType)
        showArt()
    }

    func removeArt() {
        model?.removeArt()
        showArt()
    }

    func close() {
        window.close()
        // A window never put on screen doesn't send `windowWillClose`.
        windowClosed()
    }

    public func windowWillClose(_ notification: Notification) { windowClosed() }

    /// Placing the window happens before it shows, so a move before then is the app's own.
    public func windowDidMove(_ notification: Notification) {
        guard window.isVisible, corner != placedAt else { return }
        placedAt = corner
        moved(corner)
    }

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
        tabs.heightAnchor.constraint(equalToConstant: Self.tabsHeight).isActive = true

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
        let buttons = NSStackView(views: [spinner, problemLabel, cancel, saveButton])

        collapseLabel.textColor = .systemOrange
        collapseLabel.isHidden = true
        let stack = NSStackView(views: [heading, tabs, collapseLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 20, right: 20)
        for view in [heading, tabs, collapseLabel, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        stack.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
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
        if tab == .lyrics {
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
        showLabel(view, field, edited: false)
        return view
    }

    /// The label with a dot before it when the field is edited. The dot is there, clear,
    /// otherwise, so the label doesn't move.
    private func showLabel(_ view: NSTextField, _ field: TagEditField, edited: Bool) {
        let text = NSMutableAttributedString(
            string: "● ",
            attributes: [
                .foregroundColor: edited ? NSColor.controlAccentColor : NSColor.clear,
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            ])
        text.append(
            NSAttributedString(
                string: field.title, attributes: [.font: NSFont.systemFont(ofSize: 0)]))
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

    private func artButtons(size: NSControl.ControlSize) -> NSStackView {
        let replace = NSButton(title: "Replace…", target: self, action: #selector(replaceClicked))
        let remove = NSButton(title: "Remove", target: self, action: #selector(removeClicked))
        for button in [replace, remove] {
            button.controlSize = size
            button.font = .systemFont(ofSize: NSFont.systemFontSize(for: size))
        }
        replaceButtons.append(replace)
        removeButtons.append(remove)
        return NSStackView(views: [replace, remove])
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
        for button in replaceButtons { button.isEnabled = editable }
        for button in removeButtons { button.isEnabled = editable && model?.canRemoveArt == true }
        saveButton.isEnabled = editable
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
        if !model.isTyped(.compilation) {
            compilationBox.state =
                model.isMixed(.compilation)
                ? .mixed : model.text(.compilation) == "1" ? .on : .off
        }
        showArt()
        showFile()
        showEdited()
    }

    private func showAreaPlaceholders() {
        guard let model else { return }
        for (field, placeholder) in areaPlaceholders {
            placeholder.isHidden = !(model.isMixed(field) && areas[field]?.string.isEmpty == true)
        }
    }

    private func showEdited() {
        guard let model else { return }
        for (field, views) in labels {
            for view in views { showLabel(view, field, edited: model.isEdited(field)) }
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
        for button in removeButtons { button.isEnabled = model.canRemoveArt }
    }

    private func showFile() {
        guard let model else { return }
        for row in FileRow.allCases {
            let values = Set(model.tracks.map { row.text($0) })
            fileValues[row]?.stringValue =
                row == .size
                ? FileRow.sizeText(model.tracks.compactMap(\.file?.sizeBytes).reduce(0, +))
                : values.count == 1 ? values.first! : mixedPlaceholder
        }
    }

    // MARK: Editing

    public func controlTextDidChange(_ notification: Notification) {
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

    private func showNote(_ text: String, color: NSColor) {
        problemLabel.stringValue = text
        problemLabel.toolTip = text.isEmpty ? nil : text
        problemLabel.textColor = color
    }

    @objc private func replaceClicked() { replaceArtwork() }
    @objc private func removeClicked() { removeArtwork() }
    @objc private func cancelClicked() { close() }

    @objc private func saveClicked() {
        guard let model else { return }
        do {
            saved(try model.edit())
        } catch {
            showNote(error.description, color: .systemRed)
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

/// "JPEG, 700 × 700, 126 KB": the image's type, pixels and size.
private func imageDescription(_ data: Data) -> String {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
        return FileRow.sizeText(data.count)
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
    parts.append(FileRow.sizeText(data.count))
    return parts.joined(separator: ", ")
}
