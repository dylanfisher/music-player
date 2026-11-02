import AppKit
import Commands
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
    static let statusMaximumPoints = 10_000.0
    let toolbar: NSToolbar
    /// The output picker's menu, which the app fills as it opens.
    let outputMenu = NSMenu(title: AppMenus.outputMenuTitle)
    /// The digital volume in dB, or nil when the output has none the app sets.
    var volumeDecibels: () -> Double? = { nil }
    /// Sets the digital volume in dB; `done` is false while a drag goes on, and true for every
    /// other change, which is saved.
    var setVolume: (_ decibels: Double, _ done: Bool) -> Void = { _, _ in }
    /// Called with the toolbar's items after the user adds, removes or moves one.
    var itemsChanged: ([ToolbarItem]) -> Void = { _ in }
    private let views: [ToolbarItem: NSView]
    private let dispatcher: CommandDispatcher
    private var restoring = false
    /// Set while a report of the items waits to run.
    private var reporting = false
    /// The items to show once the toolbar is in a window.
    private let savedItems: [ToolbarItem]

    /// `transport`, `status` and `search` are the views those items show. AppKit keeps the
    /// items of every toolbar with the same `identifier` the same.
    init(
        identifier: String, transport: NSView, status: NSView, search: NSView,
        dispatcher: CommandDispatcher, items: [ToolbarItem]
    ) {
        toolbar = NSToolbar(identifier: identifier)
        views = [.transport: transport, .status: status, .search: search]
        self.dispatcher = dispatcher
        savedItems = items
        super.init()
        search.translatesAutoresizingMaskIntoConstraints = false
        search.widthAnchor.constraint(equalToConstant: Self.searchPoints).isActive = true
        toolbar.delegate = self
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = false
        toolbar.displayMode = .iconOnly
    }

    /// Puts the toolbar in `window` with the saved items. A toolbar fills itself with the
    /// default items as it joins a window, so they're replaced after.
    func attach(to window: NSWindow) {
        window.toolbar = toolbar
        show(savedItems)
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
        // The customization sheet shows an image, not a second copy of a feature's view.
        if flag, let view = views[item] {
            let shown = NSToolbarItem(itemIdentifier: identifier)
            shown.view = view
            if item == .status {
                // The status takes the room the other items leave. The toolbar measures a view
                // at its fitting size, so constraints can't widen it; `minSize` and `maxSize`,
                // deprecated in macOS 12 with no replacement for a flexible width, can. KVC
                // sets them without the deprecation warning.
                let height = view.fittingSize.height
                shown.setValue(
                    NSValue(size: NSSize(width: Self.statusMinimumPoints, height: height)),
                    forKey: "minSize")
                shown.setValue(
                    NSValue(size: NSSize(width: Self.statusMaximumPoints, height: height)),
                    forKey: "maxSize")
            }
            label(shown, item)
            return shown
        }
        let made: NSToolbarItem
        switch item {
        case .shuffle, .queue, .signalPath, .repeat:
            made = CommandItem(item, dispatcher: dispatcher)
        case .volume:
            made = flag ? VolumeItem(toolbar: self) : NSToolbarItem(itemIdentifier: identifier)
        case .output:
            let output = NSMenuToolbarItem(itemIdentifier: identifier)
            output.menu = outputMenu
            made = output
        case .transport, .status, .search, .flexibleSpace, .space:
            made = NSToolbarItem(itemIdentifier: identifier)
        }
        label(made, item)
        return made
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
        case .transport: "Playback Controls"
        case .volume: "Volume"
        case .status: "Now Playing"
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
        case .search: "magnifyingglass"
        case .shuffle: "shuffle"
        case .repeat: "repeat"
        case .queue: "list.bullet"
        case .output: "hifispeaker.2"
        case .signalPath: "waveform.path"
        case .flexibleSpace, .space: ""
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
    private let slider = NSSlider(
        value: 0, minValue: MainToolbar.volumeRangeDecibels.lowerBound,
        maxValue: MainToolbar.volumeRangeDecibels.upperBound, target: nil, action: nil)

    init(toolbar: MainToolbar) {
        owner = toolbar
        super.init(itemIdentifier: ToolbarItem.volume.identifier)
        slider.controlSize = .small
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(moved)
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 90).isActive = true
        view = slider
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
