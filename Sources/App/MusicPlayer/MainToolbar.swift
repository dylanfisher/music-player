import AppKit
import Commands
import NowPlaying
import Settings

/// The main window's toolbar, which the user customizes with the standard sheet (ADR 0055).
/// The transport, the now-playing status and the search field are the features' views; the
/// other items run commands through the dispatcher, which also says whether they're on.
@MainActor
final class MainToolbar: NSObject, NSToolbarDelegate {
    /// The digital volume's range on the toolbar's slider, in dB below full.
    static let volumeRangeDecibels = -60.0...0
    static let searchPoints = 220.0
    static let statusMinimumPoints = 280.0
    /// As wide as Swinsian's status, so flexible spaces beside it keep a share of the width.
    static let statusSharingPoints = 560.0
    /// With no flexible space in the toolbar, or alone in it, a status takes all the room.
    static let statusMaximumPoints = 10_000.0
    static let volumePoints = 90.0
    static let outlineCornerRadius = 4.0
    let toolbar: NSToolbar
    /// The output picker's menu, which the app fills as it opens.
    let outputMenu = NSMenu(title: AppMenus.outputMenuTitle)
    /// The digital volume in dB, or nil when the output has none the app sets.
    var volumeDecibels: () -> Double? = { nil }
    /// Sets the digital volume in dB; `done` is false while a drag goes on, and true for every
    /// other change, which is saved.
    var setVolume: (_ decibels: Double, _ done: Bool) -> Void = { _, _ in }
    /// The now-playing status's layout, which its drawing in the customization sheet shows.
    var statusLayout = BarLayout.defaultHeaderStatus
    /// Each Custom Status item's layout, which sizes its item and its drawing shows.
    var customStatusLayouts = Dictionary(
        uniqueKeysWithValues: ToolbarItem.customStatuses.map { ($0, BarLayout.defaultCustomStatus) }
    )
    /// The title line format, which the drawings of the status and the Custom Status items show.
    var titleFormat = TitleTemplate.titleLine
    /// Called with the toolbar's items after the user adds, removes or moves one.
    var itemsChanged: ([ToolbarItem]) -> Void = { _ in }
    private let views: [ToolbarItem: NSView]
    private let dispatcher: CommandDispatcher
    private var restoring = false
    private var sheetObservers: [any NSObjectProtocol] = []
    /// Set while a report of the items waits to run.
    private var reporting = false
    /// The items to show once the toolbar is in a window.
    private let savedItems: [ToolbarItem]

    /// `transport`, `status` and `search` are the views those items show, and `customStatuses`
    /// the Custom Status items', one per slot in `ToolbarItem.customStatuses`' order. AppKit
    /// keeps the items of every toolbar with the same `identifier` the same.
    init(
        identifier: String, transport: NSView, status: NSView, customStatuses: [NSView],
        search: NSView, dispatcher: CommandDispatcher, items: [ToolbarItem]
    ) {
        precondition(
            customStatuses.count == ToolbarItem.customStatuses.count,
            "\(customStatuses.count) views for \(ToolbarItem.customStatuses.count) Custom Status items"
        )
        toolbar = NSToolbar(identifier: identifier)
        var views: [ToolbarItem: NSView] = [
            .transport: transport, .status: status, .search: search,
        ]
        for (item, view) in zip(ToolbarItem.customStatuses, customStatuses) { views[item] = view }
        self.views = views
        self.dispatcher = dispatcher
        savedItems = items
        super.init()
        search.translatesAutoresizingMaskIntoConstraints = false
        search.widthAnchor.constraint(equalToConstant: Self.searchPoints).isActive = true
        toolbar.delegate = self
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = false
        toolbar.displayMode = .iconOnly
        centersStatus(true)
    }

    /// AppKit centers the status on the window, whatever sits on either side, while it fits
    /// there at its width (ADR 0087). It never widens a centered item past what fits centered,
    /// so a status that fills the toolbar isn't centered (ADR 0094).
    private func centersStatus(_ centers: Bool) {
        let identifier = centers ? ToolbarItem.status.identifier : nil
        if #available(macOS 13, *) {
            toolbar.centeredItemIdentifiers = Set(identifier.map { [$0] } ?? [])
        } else {
            toolbar.centeredItemIdentifier = identifier
        }
    }

    /// Puts the toolbar in `window` with the saved items. A toolbar fills itself with the
    /// default items as it joins a window, so they're replaced after.
    func attach(to window: NSWindow) {
        window.toolbar = toolbar
        show(savedItems)
        let center = NotificationCenter.default
        for name in [NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification] {
            sheetObservers.append(
                center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    // The palette's sheet is attached by the time the next turn runs.
                    DispatchQueue.main.async { self?.outlineStatuses() }
                })
        }
    }

    /// Whether the status items draw their outline, which they do while Customize Toolbar's
    /// sheet is open, so an empty one can be seen and dragged out (ADR 0094).
    private(set) var outlinesStatuses = false

    /// Outlines the status and the Custom Status items while the customization palette runs,
    /// and takes the outline off after.
    private func outlineStatuses() {
        let on = toolbar.customizationPaletteIsRunning
        guard on != outlinesStatuses else { return }
        outlinesStatuses = on
        for item in [ToolbarItem.status] + ToolbarItem.customStatuses {
            guard let view = views[item] else { continue }
            view.wantsLayer = true
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                view.layer?.borderColor = NSColor.tertiaryLabelColor.cgColor
            }
            view.layer?.borderWidth = on ? 1 : 0
            view.layer?.cornerRadius = on ? Self.outlineCornerRadius : 0
        }
    }

    /// The items the toolbar holds, left to right.
    var items: [ToolbarItem] { toolbar.items.compactMap { ToolbarItem($0.itemIdentifier) } }

    /// Puts `items` in the toolbar in place of what it holds, without reporting a change.
    func show(_ items: [ToolbarItem]) {
        restoring = true
        defer { restoring = false }
        while !toolbar.items.isEmpty { toolbar.removeItem(at: 0) }
        for (index, item) in items.enumerated() {
            toolbar.insertItem(withItemIdentifier: item.identifier, at: index)
        }
        resizeStatus()
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        ToolbarItem.defaultItems.map(\.identifier)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        ToolbarItem.allCases.map(\.identifier)
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let item = ToolbarItem(identifier) else { return nil }
        if !flag, let drawing = drawing(of: item) {
            let shown = NSToolbarItem(itemIdentifier: identifier)
            shown.view = drawing
            label(shown, item)
            return shown
        }
        if flag, let view = views[item] {
            let shown = NSToolbarItem(itemIdentifier: identifier)
            shown.view = view
            if layout(of: item) != nil { size(shown, item) }
            label(shown, item)
            return shown
        }
        let made: NSToolbarItem
        switch item {
        case .shuffle, .queue, .signalPath, .repeat:
            made = CommandItem(item, dispatcher: dispatcher)
        case .volume:
            made = VolumeItem(toolbar: self)
        case .output:
            let output = NSMenuToolbarItem(itemIdentifier: identifier)
            output.menu = outputMenu
            made = output
        case .transport, .status, .customStatus1, .customStatus2, .customStatus3, .search,
            .flexibleSpace, .space:
            made = NSToolbarItem(itemIdentifier: identifier)
        }
        label(made, item)
        return made
    }

    /// The layout of the status or a Custom Status item, or nil for any other item.
    func layout(of item: ToolbarItem) -> BarLayout<HeaderPart>? {
        item == .status ? statusLayout : customStatusLayouts[item]
    }

    /// Sizes the status's and the Custom Status items again: each view's layout sets its
    /// height, and its width or, for a flexible one, whether it fills the toolbar.
    func resizeStatus() {
        for shown in toolbar.items {
            guard let item = ToolbarItem(shown.itemIdentifier), layout(of: item) != nil else {
                continue
            }
            size(shown, item)
        }
        centersStatus(!(items.contains(.status) && fills(.status)))
    }

    /// Whether a flexible status item takes all the room the other items leave: when no
    /// flexible space shares the toolbar, or when nothing but spaces is beside it (ADR 0094).
    func fills(_ item: ToolbarItem) -> Bool {
        let items = items
        return !items.contains(.flexibleSpace)
            || items.allSatisfy { [item, .space, .flexibleSpace].contains($0) }
    }

    /// A Custom Status item whose columns are all fixed is as wide as they are (ADR 0089).
    /// Any other takes the room the other items leave, as the status does, up to
    /// `statusSharingPoints` when a flexible space and another item share the toolbar, at its
    /// view's height. The toolbar measures a view at its fitting size, so constraints can't
    /// widen it; `minSize` and `maxSize`, deprecated in macOS 12 with no replacement for a
    /// flexible width, can. KVC sets them without the deprecation warning.
    private func size(_ shown: NSToolbarItem, _ item: ToolbarItem) {
        let height = shown.view?.fittingSize.height ?? 0
        var narrowest = Self.statusMinimumPoints
        var widest = fills(item) ? Self.statusMaximumPoints : Self.statusSharingPoints
        if item != .status, let layout = layout(of: item),
            let width = HeaderStatus.fixedWidthPoints(of: layout)
        {
            narrowest = width
            widest = width
        }
        shown.setValue(NSValue(size: NSSize(width: narrowest, height: height)), forKey: "minSize")
        shown.setValue(NSValue(size: NSSize(width: widest, height: height)), forKey: "maxSize")
    }

    /// What the customization sheet shows for an item whose view is a feature's: a copy of the
    /// view wired to nothing, so the sheet, the default set included, shows what the toolbar
    /// will look like. A view can be in one place only, and AppKit's sheet drew no image for
    /// these items on macOS 12.
    func drawing(of item: ToolbarItem) -> NSView? {
        switch item {
        case .transport: return NowPlayingBar.transportDrawing()
        case .status, .customStatus1, .customStatus2, .customStatus3:
            guard let layout = layout(of: item) else {
                preconditionFailure("\(item) has no layout")
            }
            return NowPlayingBar.statusDrawing(layout, titleFormat: titleFormat)
        case .search:
            let field = NSSearchField()
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: Self.searchPoints).isActive = true
            return field
        case .volume:
            let slider = VolumeItem.slider()
            slider.doubleValue = Self.volumeRangeDecibels.lowerBound / 3
            return slider
        default: return nil
        }
    }

    func toolbarWillAddItem(_ notification: Notification) { reportChange() }

    func toolbarDidRemoveItem(_ notification: Notification) { reportChange() }

    /// The toolbar adds an item after telling its delegate, so the items are read a moment
    /// later, once for all the calls a single change makes.
    private func reportChange() {
        guard !restoring, !reporting else { return }
        reporting = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            reporting = false
            resizeStatus()
            itemsChanged(items)
        }
    }

    private func label(_ made: NSToolbarItem, _ item: ToolbarItem) {
        made.label = item.label
        made.paletteLabel = item.label
        made.toolTip = item.label
        if made.view == nil, made.image == nil {
            made.image = NSImage(
                systemSymbolName: item.symbol, accessibilityDescription: item.label)
        }
    }
}

extension ToolbarItem {
    /// The spaces are AppKit's own items; the rest are named by their raw values.
    var identifier: NSToolbarItem.Identifier {
        switch self {
        case .flexibleSpace: .flexibleSpace
        case .space: .space
        default: NSToolbarItem.Identifier(rawValue)
        }
    }

    init?(_ identifier: NSToolbarItem.Identifier) {
        guard let item = Self.allCases.first(where: { $0.identifier == identifier }) else {
            return nil
        }
        self = item
    }

    var label: String {
        switch self {
        case .transport: "Controls"
        case .volume: "Volume"
        case .status: "Now Playing"
        case .customStatus1: ToolbarItem.customStatusTitle(1)
        case .customStatus2: ToolbarItem.customStatusTitle(2)
        case .customStatus3: ToolbarItem.customStatusTitle(3)
        case .search: "Search"
        case .shuffle: AppCommands.title(of: .shuffle)
        case .repeat: AppMenus.repeatMenuTitle
        case .queue: AppCommands.title(of: .toggleQueue)
        case .output: AppMenus.outputMenuTitle
        case .signalPath: AppCommands.title(of: .toggleSignalPath)
        // AppKit makes and labels its own spaces, without asking the delegate.
        case .flexibleSpace, .space: ""
        }
    }

    /// The SF Symbol the item's button, or its image in the customization sheet, shows.
    var symbol: String {
        switch self {
        case .transport: "playpause.fill"
        case .volume: "speaker.wave.2.fill"
        case .status: "music.note"
        case .customStatus1, .customStatus2, .customStatus3: "rectangle.split.3x1"
        case .search: "magnifyingglass"
        case .shuffle: "shuffle"
        case .repeat: "repeat"
        case .queue: "list.bullet"
        case .output: "hifispeaker.2"
        case .signalPath: "waveform.path"
        case .flexibleSpace, .space: ""
        }
    }

    /// The setting a Custom Status item's layout comes from, or nil for any other item.
    var customStatusSetting: KeyPath<AppSettings, Setting<BarLayout<HeaderPart>>>? {
        switch self {
        case .customStatus1: \.customStatus1Layout
        case .customStatus2: \.customStatus2Layout
        case .customStatus3: \.customStatus3Layout
        default: nil
        }
    }

    /// The command the item's button runs, for the items that are one button.
    var command: CommandID? {
        switch self {
        case .shuffle: .shuffle
        case .queue: .toggleQueue
        case .signalPath: .toggleSignalPath
        case .repeat: .repeatOff
        default: nil
        }
    }
}

/// The repeat command after the one that's on now, which the repeat button runs.
@MainActor
func nextRepeat(_ dispatcher: CommandDispatcher) -> CommandID {
    let cycle = AppMenus.repeatCommands
    let current = cycle.firstIndex { dispatcher.isOn($0) == true } ?? 0
    return cycle[(current + 1) % cycle.count]
}

/// A button that runs a command, shown pressed while the command is on. The repeat button
/// steps through the repeat modes, its symbol showing Repeat One.
@MainActor
final class CommandItem: NSToolbarItem {
    private let item: ToolbarItem
    private let dispatcher: CommandDispatcher
    private let button = NSButton()
    private var showsRepeatOne = false

    init(_ item: ToolbarItem, dispatcher: CommandDispatcher) {
        self.item = item
        self.dispatcher = dispatcher
        super.init(itemIdentifier: item.identifier)
        button.bezelStyle = .texturedRounded
        button.setButtonType(.pushOnPushOff)
        button.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.label)
        button.target = self
        button.action = #selector(clicked)
        view = button
    }

    @objc private func clicked() {
        let id = item == .repeat ? nextRepeat(dispatcher) : item.command
        if let id, !dispatcher.run(id) { NSSound.beep() }
        validate()
    }

    override func validate() {
        guard let command = item.command else { return }
        button.isEnabled = dispatcher.isEnabled(command)
        guard item == .repeat else {
            button.state = dispatcher.isOn(command) == true ? .on : .off
            return
        }
        button.state = dispatcher.isOn(.repeatOff) == false ? .on : .off
        let one = dispatcher.isOn(.repeatOne) == true
        guard one != showsRepeatOne else { return }
        showsRepeatOne = one
        button.image = NSImage(
            systemSymbolName: one ? "repeat.1" : item.symbol, accessibilityDescription: item.label)
    }
}

/// A slider for the digital volume, off when the output has none the app sets.
@MainActor
final class VolumeItem: NSToolbarItem {
    private weak var owner: MainToolbar?
    private let slider = VolumeItem.slider()

    init(toolbar: MainToolbar) {
        owner = toolbar
        super.init(itemIdentifier: ToolbarItem.volume.identifier)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(moved)
        view = slider
    }

    /// The slider, for the item and for its drawing in the customization sheet.
    static func slider() -> NSSlider {
        let slider = NSSlider(
            value: 0, minValue: MainToolbar.volumeRangeDecibels.lowerBound,
            maxValue: MainToolbar.volumeRangeDecibels.upperBound, target: nil, action: nil)
        slider.controlSize = .small
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: MainToolbar.volumePoints).isActive = true
        return slider
    }

    @objc private func moved() {
        // Arrow keys and accessibility set the slider without a drag, and each is a final value.
        let done = NSApp.currentEvent?.type != .leftMouseDragged
        owner?.setVolume(slider.doubleValue, done)
    }

    override func validate() {
        let decibels = owner?.volumeDecibels()
        slider.isEnabled = decibels != nil
        // Left alone while dragged, so the slider doesn't fight the pointer.
        if NSApp.currentEvent?.type != .leftMouseDragged {
            slider.doubleValue = decibels ?? MainToolbar.volumeRangeDecibels.upperBound
        }
    }
}
