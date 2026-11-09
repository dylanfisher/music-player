import AppKit
import KeyChord
import Settings

/// Which list the palette shows: ⌘K's commands, settings, playlists and genres, or ⌘P's artists,
/// albums and rows of the current track list, each kind in turn.
public enum PaletteMode: Equatable, Sendable {
    case commands
    case goToItem
}

/// The palette's panel: a borderless window of its own, opened on the screen of the window that
/// opened it, centered across with its top a fifth of the way down, or where it was last
/// dragged. A field over the ranked rows; the keys stay in the field. It closes when it loses
/// the keys, and gives them back to whatever had them.
@MainActor
public final class PaletteController: NSObject, NSTextFieldDelegate, NSTableViewDataSource,
    NSTableViewDelegate, NSWindowDelegate
{
    // The width, field font and corner radius are simple-spotlight's
    // (`~/projects/simple-spotlight`), so the owner's two launchers look alike; the height and
    // row count are the palette's first ones, 420 points and eleven 32-point rows (ADR 0047).
    public static let width = 680.0
    static let fieldHeight = 56.0
    static let cornerRadius = 16.0
    /// The space above and below the rows, what's left of the first height.
    static let listInset = 5.5
    static let separatorHeight = 1.0
    /// The rows the panel has room for at their least height.
    static let visibleRows = 11
    static let rowsHeight = 2 * listInset + Double(visibleRows) * PaletteRow.minimumHeight
    static let height = fieldHeight + separatorHeight + rowsHeight

    public private(set) var model: PaletteModel
    public private(set) var mode: PaletteMode?
    /// The chords that close the palette in `mode`: its own command's, as the user has them.
    public var closingChords: (PaletteMode) -> [KeyChord] = { _ in [] }
    /// Runs the chosen item; `filters` when it was chosen with ⌘↩ or ⌘-click, to filter the
    /// browser to it rather than go to it. The palette has closed by then.
    public var choose: (_ item: PaletteItem, _ filters: Bool) -> Void = { _, _ in }
    /// The chords of the key that filters the browser to the selected artist or album, as the
    /// user has them.
    public var filterChords: () -> [KeyChord] = { [] }
    /// Opens the other palette, for its chords while this one shows.
    public var open: (PaletteMode) -> Void = { _ in }
    /// Called after a choice is counted, so the app saves the frecency.
    public var visited: () -> Void = {}
    /// The panel's place changed by a drag; nil when it was dragged off every screen.
    public var placeChanged: (PalettePlace?) -> Void = { _ in }

    let panel: PalettePanel
    let field = NSTextField()
    let table = NSTableView()
    private var previousResponder: NSResponder?
    private var shownAt: NSRect?
    /// The results the table shows, kept apart from the model's so the selected row's item can
    /// be read after the model has new ones.
    private(set) var shown: [RankedItem] = []

    public init(model: PaletteModel) {
        self.model = model
        panel = PalettePanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
            styleMask: [.borderless], backing: .buffered, defer: true)
        super.init()
        build()
        model.resultsChanged = { [weak self] in self?.showResults(sameQuery: $0) }
    }

    var isShowing: Bool { panel.isVisible }

    /// The panel, for drawing it into a snapshot.
    public var window: NSWindow { panel }

    // MARK: Opening and closing

    /// Opens over `window` in `mode`, listing `items`, at `place` when the user dragged it
    /// before. Returns the listing's session, which `append` names.
    @discardableResult
    public func show(
        _ mode: PaletteMode, items: [PaletteItem], over window: NSWindow, place: PalettePlace?
    ) -> Int {
        if isShowing { close(restoringKeys: false) }
        self.mode = mode
        previousResponder = window.firstResponder
        let query = lastQueries[mode] ?? ""
        field.stringValue = query
        field.placeholderString =
            mode == .commands
            ? "Commands, settings, outputs, playlists, genres"
            : "Artists, albums, tracks; \(PaletteItem.Kind.album.keyPrefix) or "
                + "\(PaletteItem.Kind.songName): for one kind"
        panel.setAccessibilityTitle(mode == .commands ? "Command Palette" : "Go to Item")
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        let frame = Self.frame(size: panel.frame.size, on: screen, place: place)
        panel.setFrame(frame, display: false)
        shownAt = frame
        let session = model.open(
            items, byKind: mode == .goToItem, emptyQueryKinds: mode == .commands ? [.command] : nil,
            query: query)
        // Listed before the panel shows, so its first frame has the rows rather than the last
        // listing's or none. Laid out first, since a row's height depends on the table's width,
        // which the table has only after its first layout. Go to Item's kept query is ranked
        // after, since its rows can be too many to match in a frame; until then it shows the
        // rows that query listed last time.
        panel.contentView?.layoutSubtreeIfNeeded()
        if mode == .goToItem, !query.isEmpty {
            Task { await model.rank() }
        } else {
            model.rankNow()
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        // Selected, so typing replaces the kept query and Return runs its top result again.
        field.selectText(nil)
        return session
    }

    /// Each mode's last query, which it opens with again for the rest of the app's session,
    /// as Sublime Text's palette does.
    private var lastQueries: [PaletteMode: String] = [:]

    /// Clears the query in place, as the palette's own chord does while it has one.
    private func clearQuery() {
        guard let mode else { return }
        field.stringValue = ""
        lastQueries[mode] = ""
        Task { await model.setQuery("") }
    }

    /// Adds items that arrived after the palette opened `session`. They're dropped when it has
    /// opened again since.
    public func append(_ items: [PaletteItem], to session: Int) {
        Task { await model.append(items, to: session) }
    }

    public func close() { close(restoringKeys: true) }

    private func close(restoringKeys: Bool) {
        guard isShowing else { return }
        if let shownAt, panel.frame.origin != shownAt.origin {
            placeChanged(Self.place(of: panel.frame, screens: NSScreen.screens.map(\.visibleFrame)))
        }
        mode = nil
        panel.orderOut(nil)
        if restoringKeys, let previous = previousResponder,
            let window = (previous as? NSView)?.window
                ?? (previous as? NSWindow)
        {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(previous)
        }
        previousResponder = nil
    }

    public func windowDidResignKey(_ notification: Notification) {
        close(restoringKeys: false)
    }

    /// Centered across `screen`, its top a fifth of the way down, or at `place`'s share of the
    /// room the panel leaves.
    static func frame(size: NSSize, on screen: NSRect, place: PalettePlace?) -> NSRect {
        let roomX = max(0, screen.width - size.width)
        let roomY = max(0, screen.height - size.height)
        let across = place?.across ?? 0.5
        let down = place?.down ?? min(1, screen.height / 5 / max(1, roomY))
        return NSRect(
            x: screen.minX + roomX * across, y: screen.maxY - size.height - roomY * down,
            width: size.width, height: size.height)
    }

    /// `frame`'s place on the screen it's most on, clamped to that screen; nil when it's on none.
    static func place(of frame: NSRect, screens: [NSRect]) -> PalettePlace? {
        guard
            let screen = screens.max(by: {
                $0.intersection(frame).width * $0.intersection(frame).height
                    < $1.intersection(frame).width * $1.intersection(frame).height
            }), screen.intersects(frame)
        else { return nil }
        let roomX = screen.width - frame.width
        let roomY = screen.height - frame.height
        func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
        return PalettePlace(
            across: roomX > 0 ? clamp((frame.minX - screen.minX) / roomX) : 0.5,
            down: roomY > 0 ? clamp((screen.maxY - frame.maxY) / roomY) : 0)
    }

    // MARK: Keys

    /// The panel's own key equivalents, before the menu bar: its command's chords and ⌘W close
    /// it, the other palette's chords switch to it, and ⌘↩ chooses the selected row to filter.
    func takeKeyEquivalent(_ event: NSEvent) -> Bool {
        guard let mode else { return false }
        let chords = KeyChord.candidates(for: event)
        if chords.contains(Self.filterChord) {
            runSelected(filters: true)
            return true
        }
        // Its own chord clears a query first, and closes it once the field is empty.
        if !field.stringValue.isEmpty, chords.contains(where: closingChords(mode).contains) {
            clearQuery()
            return true
        }
        let close = closingChords(mode) + [KeyChord("w", .command)]
        if chords.contains(where: close.contains) {
            self.close()
            return true
        }
        let other: PaletteMode = mode == .commands ? .goToItem : .commands
        if chords.contains(where: closingChords(other).contains) {
            self.close()
            open(other)
            return true
        }
        return false
    }

    /// The filter key on an artist or album row chooses it to filter. It acts only with the
    /// insertion point at the end of the field and no input method composing, so → still moves
    /// through the query and through a composition.
    func takeFilterKey(_ event: NSEvent) -> Bool {
        guard isShowing, shown.indices.contains(table.selectedRow),
            [.artist, .album].contains(shown[table.selectedRow].item.kind),
            KeyChord.candidates(for: event).contains(where: filterChords().contains)
        else { return false }
        if let editor = field.currentEditor() {
            let selected = editor.selectedRange
            guard selected.length == 0, selected.location == (editor.string as NSString).length,
                (editor as? NSTextView)?.hasMarkedText() != true
            else { return false }
        }
        runSelected(filters: true)
        return true
    }

    public func controlTextDidChange(_ notification: Notification) {
        let text = field.stringValue
        if let mode { lastQueries[mode] = text }
        Task { await model.setQuery(text) }
    }

    public func control(
        _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
    ) -> Bool {
        let page = Self.visibleRows - 1
        switch selector {
        case #selector(NSResponder.moveDown(_:)): moveSelection(by: 1)
        case #selector(NSResponder.moveUp(_:)): moveSelection(by: -1)
        case #selector(NSResponder.scrollPageDown(_:)), #selector(NSResponder.pageDown(_:)):
            moveSelection(by: page)
        case #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.pageUp(_:)):
            moveSelection(by: -page)
        case #selector(NSResponder.insertNewline(_:)): runSelected()
        case #selector(NSResponder.cancelOperation(_:)): close()
        default: return false
        }
        return true
    }

    private func moveSelection(by step: Int) {
        let count = shown.count
        guard count > 0 else { return }
        let row = min(max(0, table.selectedRow + step), count - 1)
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    /// Chooses the selected row to filter the browser to it.
    static let filterChord = KeyChord(.return, .command)

    func runSelected(filters: Bool = false) {
        let row = table.selectedRow
        guard shown.indices.contains(row) else { return }
        let item = shown[row].item
        guard item.isEnabled else {
            NSSound.beep()
            return
        }
        // Go to Item ranks by the match alone, so its rows aren't counted.
        if item.kind != .track { model.record(item.key) }
        close()
        visited()
        choose(item, filters)
    }

    @objc private func clicked() {
        guard table.clickedRow >= 0 else { return }
        table.selectRowIndexes([table.clickedRow], byExtendingSelection: false)
        runSelected(filters: NSApp.currentEvent?.modifierFlags.contains(.command) == true)
    }

    // MARK: Views

    private func build() {
        panel.delegate = self
        panel.controller = self
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        let clip = PaletteClip()

        let glass = NSImageView(
            image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
                ?? NSImage())
        glass.symbolConfiguration = .init(pointSize: 18, weight: .regular)
        glass.contentTintColor = .secondaryLabelColor
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 24, weight: .light)
        field.delegate = self
        let top = NSStackView(views: [glass, field])
        top.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        let separator = NSBox()
        separator.boxType = .separator

        let column = NSTableColumn(identifier: PaletteRow.identifier)
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .fullWidth
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.refusesFirstResponder = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(
            top: Self.listInset, left: 0, bottom: Self.listInset, right: 0)

        let stack = NSStackView(views: [top, separator, scroll])
        stack.orientation = .vertical
        stack.spacing = 0
        for view in [top, separator, scroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        top.heightAnchor.constraint(equalToConstant: Self.fieldHeight).isActive = true
        separator.heightAnchor.constraint(equalToConstant: Self.separatorHeight).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: Self.rowsHeight).isActive = true
        // Liquid Glass from macOS 26 (ADR 0150), holding the stack so its text takes the glass's
        // vibrancy; the popover material behind it before.
        let material: NSView
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = Self.cornerRadius
            glass.contentView = stack
            material = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.addSubview(stack)
            material = effect
        }
        clip.addSubview(material)
        for (view, container) in [(stack, material), (material, clip)] {
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                view.topAnchor.constraint(equalTo: container.topAnchor),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        panel.contentView = clip
    }

    /// Shows the model's new results. When they rank the same query, as when items were
    /// appended, the selected item stays selected; otherwise the best match is.
    private func showResults(sameQuery: Bool) {
        let selected = shown.indices.contains(table.selectedRow) ? shown[table.selectedRow] : nil
        shown = model.results
        table.reloadData()
        guard !shown.isEmpty else { return }
        let row =
            sameQuery
            ? selected.flatMap { old in shown.firstIndex { $0.item.key == old.item.key } }
            : nil
        table.selectRowIndexes([row ?? 0], byExtendingSelection: false)
        table.scrollRowToVisible(row ?? 0)
    }

    public func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        let cell =
            tableView.makeView(withIdentifier: PaletteRow.identifier, owner: nil) as? PaletteRow
            ?? PaletteRow()
        cell.show(shown[row])
        return cell
    }

    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        PaletteRow.height(of: shown[row], width: tableView.bounds.width)
    }

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        PaletteRowView()
    }
}

/// A borderless panel that can still take the keys, and offers them to its controller first:
/// a key equivalent before the menu bar, and the filter key before the field.
final class PalettePanel: NSPanel {
    weak var controller: PaletteController?

    override var canBecomeKey: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Before the menu bar, which would otherwise take a filter key with ⌘, ⌃ or ⌥.
        if controller?.takeKeyEquivalent(event) == true || controller?.takeFilterKey(event) == true
        {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        // Before the field, for a filter key that isn't a key equivalent, as → isn't.
        if event.type == .keyDown, controller?.takeFilterKey(event) == true { return }
        super.sendEvent(event)
    }
}

/// The panel's rounded content, with a hairline edge that follows the appearance as it changes:
/// white at 60% in light mode and 20% in dark, as Spotlight's.
final class PaletteClip: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = PaletteController.cornerRadius
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        updateEdge()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateEdge()
    }

    private func updateEdge() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.borderColor = NSColor.white.withAlphaComponent(dark ? 0.2 : 0.6).cgColor
    }
}

/// Draws the selection as Searcher's palette does, which is the inset table style's: the
/// focused selection color, rounded and inset from the sides. The style itself isn't used, since
/// it pads the rows by 10 points above and below, which the panel's height has no room for.
final class PaletteRowView: NSTableRowView {
    static let selectionColor = NSColor.selectedContentBackgroundColor
    static let selectionInset = 10.0
    static let selectionRadius = 6.0

    override func drawSelection(in dirtyRect: NSRect) {
        Self.selectionColor.setFill()
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: Self.selectionInset, dy: 0),
            xRadius: Self.selectionRadius, yRadius: Self.selectionRadius
        ).fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        isSelected ? .emphasized : .normal
    }
}
