import AppKit
import Testing

@testable import Commands
@testable import MusicPlayer
@testable import NowPlaying
@testable import Settings

@MainActor
private func dispatcher() throws -> CommandDispatcher {
    CommandDispatcher(
        bindings: try KeyBindings(
            AppCommands.all(), overrides: [:], rules: AppMenus.rules(appName: "App")))
}

/// A toolbar of stand-in views in a window, showing `items`.
@MainActor
private func toolbar(_ items: [ToolbarItem], _ dispatcher: CommandDispatcher) -> MainToolbar {
    let toolbar = MainToolbar(
        identifier: UUID().uuidString, transport: NSView(), status: NSView(),
        search: NSSearchField(), dispatcher: dispatcher, items: items)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1200, height: 400), styleMask: [.titled],
        backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    toolbar.attach(to: window)
    return toolbar
}

/// Lets the toolbar's change report, which comes a turn later, run.
@MainActor
private func nextTurn() async {
    await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
}

@MainActor @Test func theToolbarShowsTheSavedItemsDownToNone() throws {
    let dispatcher = try dispatcher()
    let saved: [ToolbarItem] = [
        .search, .space, .volume, .flexibleSpace, .status, .repeat, .output, .space,
    ]
    #expect(toolbar(saved, dispatcher).items == saved)
    #expect(toolbar([], dispatcher).items.isEmpty)
    #expect(toolbar(ToolbarItem.defaultItems, dispatcher).items == ToolbarItem.defaultItems)
}

@MainActor @Test func everyItemCanBeAddedAndHasAnImage() throws {
    let made = toolbar([], try dispatcher())
    let allowed = made.toolbarAllowedItemIdentifiers(made.toolbar)
    #expect(allowed == ToolbarItem.allCases.map(\.identifier))
    for item in ToolbarItem.allCases where ![.space, .flexibleSpace].contains(item) {
        #expect(NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil) != nil)
        let shown = made.toolbar(
            made.toolbar, itemForItemIdentifier: item.identifier, willBeInsertedIntoToolbar: false)
        #expect(shown?.paletteLabel == item.label, "\(item)")
        #expect(shown?.label.isEmpty == false, "\(item)")
    }
}

@MainActor @Test func removingOrAddingAnItemReportsTheItems() async throws {
    let made = toolbar([.transport, .status, .queue, .search], try dispatcher())
    var reported: [[ToolbarItem]] = []
    made.itemsChanged = { reported.append($0) }
    made.toolbar.removeItem(at: 0)
    await nextTurn()
    #expect(reported == [[.status, .queue, .search]])
    made.toolbar.insertItem(withItemIdentifier: ToolbarItem.shuffle.identifier, at: 3)
    await nextTurn()
    #expect(reported.last == [.status, .queue, .search, .shuffle])
    // Showing saved items isn't a change the user made.
    made.show([.queue])
    await nextTurn()
    #expect(reported.count == 2)
}

/// Swinsian's set, with the status in the middle and the queue left to the menu and its keys.
@MainActor @Test func theDefaultSetIsSwinsians() throws {
    #expect(
        ToolbarItem.defaultItems == [
            .transport, .flexibleSpace, .volume, .flexibleSpace, .status, .flexibleSpace,
            .shuffle, .flexibleSpace, .search,
        ])
    let made = toolbar([], try dispatcher())
    #expect(
        made.toolbarDefaultItemIdentifiers(made.toolbar)
            == ToolbarItem.defaultItems.map(\.identifier))
    #expect(ToolbarItem.transport.label == "Controls")
}

/// A toolbar saved before the status had a layout lists the same items, which all come back.
@MainActor @Test func aToolbarSavedBeforeTheLayoutComesBackWhole() throws {
    let saved: [ToolbarItem] = [.transport, .status, .queue, .search]
    #expect(toolbar(saved, try dispatcher()).items == saved)
}

/// The status's item takes its view's height again when its layout changes: one line is lower
/// than the default's three over a seek bar.
@MainActor @Test func aLayoutChangeSizesTheStatusAgain() throws {
    let header = HeaderStatus()
    let made = MainToolbar(
        identifier: UUID().uuidString, transport: NSView(), status: header.view,
        search: NSSearchField(), dispatcher: try dispatcher(), items: [.status])
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1200, height: 400), styleMask: [.titled],
        backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    made.attach(to: window)
    let item = try #require(made.toolbar.items.first)
    let tall = try #require((item.value(forKey: "minSize") as? NSValue)?.sizeValue.height)
    #expect(tall == header.view.fittingSize.height)
    let oneLine = BarLayout<HeaderPart>(
        center: BarColumn(parts: [.title], width: .flexible, alignment: .center))
    header.apply(oneLine)
    made.statusLayout = oneLine
    made.resizeStatus()
    let short = try #require((item.value(forKey: "maxSize") as? NSValue)?.sizeValue.height)
    #expect(short == header.view.fittingSize.height && short < tall, "\(short) \(tall)")
}

/// Beside a flexible space the status stops at Swinsian's width so the space keeps a share;
/// without one, as in a toolbar saved before the default set had them, it fills the room as it
/// did. Adding or removing a space changes it.
@MainActor @Test func theStatusFillsUnlessAFlexibleSpaceShares() async throws {
    func widest(_ made: MainToolbar) throws -> CGFloat {
        let item = try #require(
            made.toolbar.items.first { ToolbarItem($0.itemIdentifier) == .status })
        return try #require((item.value(forKey: "maxSize") as? NSValue)?.sizeValue.width)
    }
    let dispatcher = try dispatcher()
    let shared = toolbar(ToolbarItem.defaultItems, dispatcher)
    #expect(try widest(shared) == MainToolbar.statusSharingPoints)
    let old = toolbar([.transport, .status, .queue, .search], dispatcher)
    #expect(try widest(old) == MainToolbar.statusMaximumPoints)
    old.toolbar.insertItem(withItemIdentifier: .flexibleSpace, at: 0)
    await nextTurn()
    #expect(try widest(old) == MainToolbar.statusSharingPoints)
    old.toolbar.removeItem(at: 0)
    await nextTurn()
    #expect(try widest(old) == MainToolbar.statusMaximumPoints)
}

@MainActor @Test func theRepeatButtonStepsThroughTheModes() throws {
    let dispatcher = try dispatcher()
    var mode = CommandID.repeatOff
    for id in AppMenus.repeatCommands {
        dispatcher.handle(id, isOn: { mode == id }, run: { mode = id })
    }
    let item = CommandItem(.repeat, dispatcher: dispatcher)
    let button = try #require(item.view as? NSButton)
    // A click reaches its target through NSApp, which a test run alone hasn't made yet.
    _ = NSApplication.shared
    var seen: [CommandID] = []
    for _ in AppMenus.repeatCommands {
        button.performClick(nil)
        seen.append(mode)
    }
    #expect(seen == [.repeatAll, .repeatOne, .repeatOff])
}

@MainActor @Test func aCommandButtonShowsWhetherItsCommandIsOn() throws {
    let dispatcher = try dispatcher()
    var shuffling = false
    var enabled = false
    dispatcher.handle(
        .shuffle, enabled: { enabled }, isOn: { shuffling }, run: { shuffling.toggle() })
    let item = CommandItem(.shuffle, dispatcher: dispatcher)
    let button = try #require(item.view as? NSButton)
    _ = NSApplication.shared
    item.validate()
    #expect(!button.isEnabled)
    enabled = true
    item.validate()
    #expect(button.isEnabled)
    #expect(button.state == .off)
    button.performClick(nil)
    #expect(shuffling)
    #expect(button.state == .on)
}

@MainActor @Test func aVolumeChangeOutsideADragIsSaved() throws {
    let made = toolbar([.volume], try dispatcher())
    var set: [(Double, Bool)] = []
    made.setVolume = { set.append(($0, $1)) }
    let item = try #require(made.toolbar.items.first as? VolumeItem)
    let slider = try #require(item.view as? NSSlider)
    slider.doubleValue = -12
    // As the arrow keys change it, with no mouse event under way.
    slider.sendAction(slider.action, to: slider.target)
    #expect(set.count == 1)
    #expect(set.first?.0 == -12 && set.first?.1 == true)
}

@MainActor @Test func theSheetDrawsTheItemsThatAreAFeaturesView() throws {
    let made = toolbar([.transport, .status, .search, .volume], try dispatcher())
    for (index, item) in [ToolbarItem.transport, .status, .search, .volume].enumerated() {
        let shown = made.toolbar(
            made.toolbar, itemForItemIdentifier: item.identifier, willBeInsertedIntoToolbar: false)
        let drawing = try #require(shown?.view, "\(item) has no drawing")
        #expect(drawing.fittingSize.width > 0, "\(item)")
        // A copy, so the toolbar keeps its own view.
        #expect(drawing !== made.toolbar.items[index].view, "\(item)")
    }
}
