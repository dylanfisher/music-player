import AppKit
import Testing

@testable import Commands
@testable import MusicPlayer
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
        search: NSSearchField(), dispatcher: dispatcher,
        items: items)
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
    let made = toolbar(ToolbarItem.defaultItems, try dispatcher())
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

@MainActor @Test func theRepeatButtonStepsThroughTheModes() throws {
    let dispatcher = try dispatcher()
    var mode = CommandID.repeatOff
    for id in repeatCycle {
        dispatcher.handle(id, isOn: { mode == id }, run: { mode = id })
    }
    let item = CommandItem(.repeat, dispatcher: dispatcher)
    let button = try #require(item.view as? NSButton)
    // A click reaches its target through NSApp, which a test run alone hasn't made yet.
    _ = NSApplication.shared
    var seen: [CommandID] = []
    for _ in repeatCycle {
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
