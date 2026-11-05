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

/// A view for each Custom Status item.
@MainActor
private func slots() -> [NSView] { ToolbarItem.customStatuses.map { _ in NSView() } }

/// A toolbar of stand-in views in a window, showing `items`; `customStatuses` are the Custom
/// Status items' views.
@MainActor
private func toolbar(
    _ items: [ToolbarItem], _ dispatcher: CommandDispatcher, customStatuses: [NSView] = slots()
) -> MainToolbar {
    let toolbar = MainToolbar(
        identifier: UUID().uuidString, transport: NSView(), status: NSView(),
        customStatuses: customStatuses, search: NSSearchField(), dispatcher: dispatcher,
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
        customStatuses: slots(),
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

/// The status centers on the window whatever sits on either side of it: nothing on the left
/// and Search on the right, as the owner lays it out, the default set, and a lopsided one; with
/// the glass's full-size content view too.
@MainActor @Test(arguments: [false, true])
func theStatusCentersOnTheWindow(_ fullSize: Bool) throws {
    let sets: [[ToolbarItem]] = [
        [.flexibleSpace, .status, .flexibleSpace, .search],
        ToolbarItem.defaultItems,
        [.transport, .volume, .shuffle, .repeat, .flexibleSpace, .status, .flexibleSpace, .search],
    ]
    for items in sets {
        let header = HeaderStatus()
        let made = MainToolbar(
            identifier: UUID().uuidString, transport: NSView(), status: header.view,
            customStatuses: slots(),
            search: NSSearchField(), dispatcher: try dispatcher(), items: items)
        var style: NSWindow.StyleMask = [.titled, .resizable]
        if fullSize { style.insert(.fullSizeContentView) }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 400), styleMask: style,
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.toolbarStyle = .expanded
        made.attach(to: window)
        window.orderFront(nil)
        for width in [1440.0, 1280] {
            window.setContentSize(NSSize(width: width, height: 400))
            window.layoutIfNeeded()
            let status = header.view.convert(header.view.bounds, to: nil)
            #expect(abs(status.midX - width / 2) <= 0.5, "\(items) at \(width): \(status)")
        }
    }
}

/// The sheet draws the status's title line with the owner's format, not the default.
@MainActor @Test func theSheetsStatusDrawingUsesTheTitleFormat() throws {
    let made = toolbar([.status], try dispatcher())
    made.statusLayout = BarLayout(
        center: BarColumn(parts: [.titleLine], width: .flexible, alignment: .leading))
    made.titleFormat = TitleTemplate("{artist}: {title}")
    func texts(_ view: NSView) -> [String] {
        ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap(texts)
    }
    let drawing = try #require(made.drawing(of: .status))
    #expect(texts(drawing).contains("The Artist: Song Title"), "\(texts(drawing))")
}

/// Customize Toolbar offers the three Custom Status items beside the status, none of them in
/// the default set, and only the status is centered.
@MainActor @Test func theCustomStatusesAreOfferedButNotInTheDefaultSet() throws {
    let made = toolbar([], try dispatcher())
    let allowed = made.toolbarAllowedItemIdentifiers(made.toolbar)
    let status = try #require(allowed.firstIndex(of: ToolbarItem.status.identifier))
    #expect(
        Array(allowed[(status + 1)...].prefix(3))
            == ToolbarItem.customStatuses.map(\.identifier))
    #expect(ToolbarItem.customStatuses.allSatisfy { !ToolbarItem.defaultItems.contains($0) })
    #expect(
        ToolbarItem.customStatuses.map(\.label) == [
            "Custom Status 1", "Custom Status 2", "Custom Status 3",
        ])
    #expect(made.toolbar.centeredItemIdentifiers == [ToolbarItem.status.identifier])
}

/// The status and the Custom Status items can all be in the toolbar at once, anywhere in it,
/// each showing its own view, and a saved toolbar with them comes back whole.
@MainActor @Test func theCustomStatusesGoAnywhereBesideTheStatus() throws {
    let views = slots()
    let saved: [ToolbarItem] = [
        .customStatus2, .transport, .flexibleSpace, .status, .flexibleSpace, .customStatus1,
        .search, .customStatus3,
    ]
    let made = toolbar(saved, try dispatcher(), customStatuses: views)
    #expect(made.items == saved)
    for (item, view) in zip(ToolbarItem.customStatuses, views) {
        let shown = made.toolbar.items.first { ToolbarItem($0.itemIdentifier) == item }
        #expect(shown?.view === view, "\(item)")
    }
}

/// The sheet draws each Custom Status item from its own layout, with the owner's title format.
@MainActor @Test func theSheetDrawsEachCustomStatusFromItsLayout() throws {
    let made = toolbar([], try dispatcher())
    made.titleFormat = TitleTemplate("{artist}: {title}")
    made.customStatusLayouts[.customStatus2] = BarLayout(
        center: BarColumn(parts: [.format], width: .flexible, alignment: .center))
    func texts(_ view: NSView) -> [String] {
        // Only what shows: a layout leaves its other parts out of the view tree.
        ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap(texts)
    }
    let first = try #require(made.drawing(of: .customStatus1))
    #expect(texts(first).contains("The Artist: Song Title"), "\(texts(first))")
    #expect(!texts(first).contains("44.1 kHz 16-bit FLAC"))
    let second = try #require(made.drawing(of: .customStatus2))
    #expect(texts(second).contains("44.1 kHz 16-bit FLAC"), "\(texts(second))")
    #expect(!texts(second).contains("The Artist: Song Title"))
    // Fixed columns are drawn at their width, as the item is sized.
    made.customStatusLayouts[.customStatus3] = BarLayout(
        center: BarColumn(parts: [.titleLine], width: .fixed(300), alignment: .center))
    let third = try #require(made.drawing(of: .customStatus3))
    #expect(
        abs(third.fittingSize.width - 300 * NowPlayingBar.drawingScale) < 0.5,
        "\(third.fittingSize)")
}

/// A Custom Status item of fixed columns is as wide as they are; with a flexible column it's
/// sized as the status is. A layout change sizes it again, height and width.
@MainActor @Test func aCustomStatusTakesItsLayoutsWidth() throws {
    let headers = ToolbarItem.customStatuses.map { _ in HeaderStatus() }
    let made = toolbar(
        [.flexibleSpace, .customStatus1, .customStatus2], try dispatcher(),
        customStatuses: headers.map(\.view))
    func size(_ item: ToolbarItem, _ key: String) throws -> NSSize {
        let shown = try #require(
            made.toolbar.items.first { ToolbarItem($0.itemIdentifier) == item })
        return try #require((shown.value(forKey: key) as? NSValue)?.sizeValue)
    }
    #expect(try size(.customStatus1, "minSize").width == MainToolbar.statusMinimumPoints)
    #expect(try size(.customStatus1, "maxSize").width == MainToolbar.statusSharingPoints)
    let fixed = BarLayout<HeaderPart>(
        leading: [BarColumn(parts: [.art], width: .fixed(48), alignment: .leading)],
        center: BarColumn(parts: [.titleLine], width: .fixed(180), alignment: .leading))
    headers[1].apply(fixed)
    made.customStatusLayouts[.customStatus2] = fixed
    made.resizeStatus()
    let width = 48 + 180 + HeaderStatus.spacingPoints
    #expect(try size(.customStatus2, "minSize").width == width)
    #expect(try size(.customStatus2, "maxSize") == NSSize(width: width, height: 48))
    #expect(try size(.customStatus1, "maxSize").width == MainToolbar.statusSharingPoints)
}

/// A status with a flexible column fills the toolbar when nothing but spaces is beside it, or
/// when no flexible space shares the toolbar: the status, which AppKit only widens while it
/// isn't centered, and a Custom Status item between flexible spaces. Beside other items and a
/// flexible space the status keeps Swinsian's width, centered.
@MainActor @Test func aStatusAloneFillsTheToolbar() throws {
    let fills: [([ToolbarItem], ToolbarItem)] = [
        ([.status], .status), ([.flexibleSpace, .status, .flexibleSpace], .status),
        ([.transport, .status, .search], .status), ([.customStatus1], .customStatus1),
        ([.flexibleSpace, .customStatus1, .flexibleSpace], .customStatus1),
    ]
    let shares: [([ToolbarItem], ToolbarItem)] = [
        (ToolbarItem.defaultItems, .status),
        ([.transport, .flexibleSpace, .customStatus1, .flexibleSpace], .customStatus1),
    ]
    for (items, item) in fills + shares {
        let header = HeaderStatus()
        let slots = ToolbarItem.customStatuses.map { _ in HeaderStatus() }
        let made = MainToolbar(
            identifier: UUID().uuidString, transport: NSView(), status: header.view,
            customStatuses: slots.map(\.view), search: NSSearchField(),
            dispatcher: try dispatcher(), items: items)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 400),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.toolbarStyle = .expanded
        made.attach(to: window)
        window.orderFront(nil)
        window.layoutIfNeeded()
        let view = item == .status ? header.view : slots[0].view
        let width = view.convert(view.bounds, to: nil).width
        if fills.contains(where: { $0.0 == items }) {
            // All but the search field's 220 points and the toolbar's margins.
            #expect(width > 1200 - MainToolbar.searchPoints - 100, "\(items): \(width)")
        } else {
            #expect(abs(width - MainToolbar.statusSharingPoints) < 0.5, "\(items): \(width)")
        }
    }
}
