import AppKit
import Settings
import Testing

@testable import MusicPlayer

/// Column spacing and a vertical scroller, which the table adds to its columns' widths.
private let tableExtraPoints = 6.0 + 15.0

@MainActor @Test func theDefaultColumnsFitBesideTheSidebarAndQueue() {
    let settings = AppState()
    let columns = settings.trackTable.defaultValue.columns
    let needed = columns.reduce(0) { $0 + $1.width + 6 } + tableExtraPoints
    let room =
        Double(MainWindow.defaultSize.width) - Double(settings.sidebarWidth.defaultValue)
        - Double(settings.queueWidth.defaultValue)
    #expect(needed <= room)
}

/// A split of empty views in a window of the default size, as the main window lays it out.
@MainActor
private func split(queueVisible: Bool) -> (MainSplit, NSWindow, content: NSView) {
    let views = (0..<3).map { _ in
        let controller = NSViewController()
        controller.view = NSView()
        return controller
    }
    let split = MainSplit(
        sidebar: views[0], content: views[1], queue: views[2], sidebarWidth: 180,
        queueWidth: 220)
    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: MainWindow.defaultSize),
        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.contentView = split.view
    window.layoutIfNeeded()
    split.restore(sidebarVisible: true, queueVisible: queueVisible)
    return (split, window, views[1].view)
}

@MainActor @Test func aHiddenQueueLeavesNoDividerAndStaysHiddenAsTheWindowResizes() {
    let (split, window, content) = split(queueVisible: true)
    split.toggleQueue()
    for width in [1000.0, 1400.0] {
        window.setFrame(NSRect(x: 0, y: 0, width: width, height: 760), display: false)
        window.layoutIfNeeded()
        let splitView = split.controller.splitView
        #expect(!split.isQueueVisible)
        // The browser reaches the window's edge: no divider is left to drag.
        split.view.layoutSubtreeIfNeeded()
        #expect(abs(content.convert(content.bounds, to: nil).maxX - width) < 0.5)
        #expect(split.controller.splitView(splitView, shouldHideDividerAt: 1))
    }
}

@MainActor @Test func theQueueComesBackAtItsWidth() {
    let (split, window, _) = split(queueVisible: false)
    #expect(!split.isQueueVisible)
    split.toggleQueue()
    window.layoutIfNeeded()
    let queue = split.controller.splitViewItems[2].viewController.view
    #expect(split.isQueueVisible)
    #expect(abs(queue.frame.width - 220) <= 1)
}

/// The widths saved are the ones a launch puts back: a drag of the sidebar's and the queue's
/// dividers saves widths that a split restored with them shows again, to the point.
@MainActor @Test func theSidebarAndQueueWidthsSavedComeBackTheSame() {
    let (split, window, _) = split(queueVisible: true)
    window.orderFront(nil)
    var saved = (sidebar: 0, queue: 0)
    split.sidebarWidthChanged = { saved.sidebar = $0 }
    split.queueWidthChanged = { saved.queue = $0 }
    let view = split.controller.splitView
    view.setPosition(240, ofDividerAt: 0)
    view.setPosition(view.bounds.width - 300, ofDividerAt: 1)
    let dragged = view.arrangedSubviews.map { Int($0.frame.width.rounded()) }
    #expect(saved == (dragged[0], dragged[2]))

    let restored = MainSplit(
        sidebar: NSViewController(nibName: nil, bundle: nil).withView(),
        content: NSViewController(nibName: nil, bundle: nil).withView(),
        queue: NSViewController(nibName: nil, bundle: nil).withView(),
        sidebarWidth: saved.sidebar, queueWidth: saved.queue)
    let again = NSWindow(
        contentRect: NSRect(origin: .zero, size: MainWindow.defaultSize),
        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    again.isReleasedWhenClosed = false
    again.contentView = restored.view
    again.layoutIfNeeded()
    restored.restore(sidebarVisible: true, queueVisible: true)
    let widths = restored.controller.splitView.arrangedSubviews.map {
        Int($0.frame.width.rounded())
    }
    #expect((widths[0], widths[2]) == (dragged[0], dragged[2]))
}

extension NSViewController {
    /// The controller with an empty view of its own.
    fileprivate func withView() -> NSViewController {
        view = NSView()
        return self
    }
}

/// Records the key presses no responder took, which AppKit beeps for.
private final class RecordingWindow: SilentEscapeWindow {
    var unhandled: [Selector] = []

    override func noResponder(for eventSelector: Selector) { unhandled.append(eventSelector) }
}

@MainActor @Test func escapeInAListDoesNothingWhereOtherKeysStillBeep() throws {
    let window = RecordingWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
        backing: .buffered, defer: false)
    let table = NSTableView()
    window.contentView = table
    #expect(window.makeFirstResponder(table))
    func press(_ characters: String, _ keyCode: UInt16) throws {
        table.keyDown(
            with: try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: characters,
                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)))
    }
    try press("\u{1B}", 53)
    #expect(window.unhandled.isEmpty)
    #expect(table.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: nil))
    // A key nothing takes still reaches AppKit's beep.
    try press("\u{F704}", 122)
    #expect(window.unhandled == [#selector(NSResponder.keyDown(with:))])
}

/// Full screen gives the window the screen's frame, which isn't one to open it at: the frame it
/// had before is kept, and the frames after it left are saved again.
@MainActor @Test func aFrameInFullScreenIsntSaved() async throws {
    let fixture = try await MainWindowFixture()
    defer { fixture.close() }
    let window = fixture.window.window
    let screen = try #require(window.screen?.frame)
    let windowed = NSRect(x: 40, y: 60, width: 1000, height: 700)
    window.setFrame(windowed, display: false)
    func saved() -> NSRect? {
        fixture.saver.flush()
        return fixture.state[\.windowFrame].map {
            NSRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
        }
    }
    #expect(saved() == windowed)
    // The delegate calls AppKit makes around the change, without the animation.
    let notification = Notification(name: NSWindow.willEnterFullScreenNotification, object: window)
    fixture.window.windowWillEnterFullScreen(notification)
    window.setFrame(screen, display: false)
    #expect(saved() == windowed)
    fixture.window.windowDidExitFullScreen(notification)
    let moved = NSRect(x: 80, y: 60, width: 1000, height: 700)
    window.setFrame(moved, display: false)
    #expect(saved() == moved)
}

@Test func aVisibilityIsSavedOnlyWhenItChanged() {
    var saved = SavedVisibility(true)
    let changes = [true, false, false, true].map { saved.change(to: $0) }
    #expect(changes == [false, true, false, true])
}
