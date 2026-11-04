import AppKit
import KeyChord
import LibraryBrowser
import NowPlaying
import QueueView
import Settings

/// The app's name, as the window title and the app menu show it.
let appName = ProcessInfo.processInfo.processName

/// The main window: the toolbar, the config file's banner when it has a problem, the signal
/// path when shown, then the sidebar, the browser and the queue side by side. It places the
/// features' views and reports layout changes; it holds no logic of its own.
@MainActor
final class MainWindow: NSObject, NSWindowDelegate {
    /// The window's size before it has a saved frame: inside a 1440 by 900 screen, the 2015
    /// MacBook Pro's, with room for the default columns beside the sidebar and the queue.
    static let defaultSize = NSSize(width: 1280, height: 760)
    let window: NSWindow
    private let split: MainSplit
    private let signalPath: SignalPathPanel
    private let browser: LibraryBrowser
    private let saver: LayoutSaver
    private var restoring = true
    /// What Distraction-Free Mode hid, while it's on.
    private var hidden: ChromeVisibility?
    private var toolbarObservation: NSKeyValueObservation?
    private var savedToolbar: SavedVisibility
    private var glass: WindowGlass?

    init(
        settings: WindowSettings, banner: NSView, browser: LibraryBrowser, toolbar: MainToolbar,
        signalPath: SignalPathPanel, queue: QueuePanel, saver: LayoutSaver
    ) {
        split = MainSplit(
            sidebar: browser.sidebar, content: browser.content, queue: queue,
            sidebarWidth: settings.sidebarWidth, queueWidth: settings.queueWidth)
        self.signalPath = signalPath
        self.browser = browser
        self.saver = saver
        savedToolbar = SavedVisibility(settings.toolbarVisible)
        window = SilentEscapeWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
            defer: false)
        super.init()
        window.title = appName
        window.minSize = NSSize(width: 720, height: 420)
        window.delegate = self
        window.isReleasedWhenClosed = false
        // Under the title, where the toolbar grows to the now-playing status's height.
        window.toolbarStyle = .expanded
        toolbar.attach(to: window)
        toolbar.toolbar.isVisible = settings.toolbarVisible
        // The toolbar's own context menu can hide it too. `isVisible` reports changes to an
        // observer only from macOS 14; before, the state is saved as the window closes and the
        // app quits.
        if #available(macOS 14, *) {
            toolbarObservation = toolbar.toolbar.observe(\.isVisible) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.saveToolbarVisibility() }
            }
        }

        split.sidebarWidthChanged = { saver.set(\.sidebarWidth, $0) }
        split.queueWidthChanged = { saver.set(\.queueWidth, $0) }

        let line = NSBox()
        line.boxType = .separator
        signalPath.view.isHidden = !settings.signalPathVisible
        let stack = NSStackView(views: [banner, signalPath.view, line, split.view])
        stack.orientation = .vertical
        stack.spacing = 0
        for view in [banner, signalPath.view, line, split.view] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        glass = WindowGlass(window: window, content: stack)
        glass?.set(settings.tableAppearance.glass)
        centerStatusBarUnderTitle()

        if let frame = restoredFrame(
            settings.frame, screens: NSScreen.screens.map(\.visibleFrame))
        {
            window.setFrame(frame, display: false)
        } else {
            window.center()
        }
        window.layoutIfNeeded()
        split.restore(sidebarVisible: settings.sidebarVisible, queueVisible: settings.queueVisible)
        browser.restoreSplit()
        restoring = false
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
    }

    /// Titles the window from now on as `nowPlaying` fills `template`, the app's name with
    /// nothing playing.
    func showTitles(of nowPlaying: NowPlayingBar, _ template: WindowTitle) {
        nowPlaying.windowTitleChanged = { [weak self] in self?.window.title = $0 ?? appName }
        nowPlaying.windowTitle = template
    }

    var isSidebarVisible: Bool { split.isSidebarVisible }
    var isQueueVisible: Bool { split.isQueueVisible }
    var isSignalPathVisible: Bool { !signalPath.view.isHidden }

    func toggleSidebar() {
        split.toggleSidebar()
        saver.set(\.sidebarVisible, isSidebarVisible)
    }

    func showSidebar() {
        if !isSidebarVisible { toggleSidebar() }
    }

    func toggleQueue() {
        split.toggleQueue()
        saver.set(\.queueVisible, isQueueVisible)
    }

    var isToolbarVisible: Bool { window.toolbar?.isVisible == true }

    func toggleToolbar() {
        window.toolbar?.isVisible.toggle()
        saveToolbarVisibility()
    }

    /// Saves whether the toolbar shows, when that changed since the last save.
    func saveToolbarVisibility() {
        guard !restoring, savedToolbar.change(to: isToolbarVisible) else { return }
        saver.set(\.toolbarVisible, isToolbarVisible)
    }

    func toggleStatusBar() {
        browser.toggleStatusBar()
        saver.set(\.statusBarVisible, browser.isStatusBarVisible)
    }

    /// Whether the toolbar, the sidebar and the status bar are all hidden.
    var isDistractionFree: Bool { chrome == .hidden }

    private var chrome: ChromeVisibility {
        ChromeVisibility(
            toolbar: isToolbarVisible, sidebar: isSidebarVisible,
            statusBar: browser.isStatusBarVisible)
    }

    /// Hides the toolbar, the sidebar and the status bar, or shows what it hid.
    func toggleDistractionFree() {
        let current = chrome
        let next = current.toggled(hid: &hidden)
        if next.toolbar != current.toolbar { toggleToolbar() }
        if next.sidebar != current.sidebar { toggleSidebar() }
        if next.statusBar != current.statusBar { toggleStatusBar() }
    }

    /// Puts the window's content on glass, or takes it off. The frame that puts back is no move
    /// of the user's, so it isn't saved, and nor are the dividers on the way back.
    func setGlass(_ on: Bool) {
        restoring = true
        split.keepingWidths { glass?.set(on) }
        restoring = false
        centerStatusBarUnderTitle()
    }

    /// With a full-size content view AppKit centers the title over the area beside the sidebar,
    /// so the status bar's middle centers there too (ADR 0085).
    private func centerStatusBarUnderTitle() {
        browser.centerStatusBar(besideSidebar: window.styleMask.contains(.fullSizeContentView))
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        restoring = true
        split.keepingWidths { glass?.matchStyleMask() }
        restoring = false
        centerStatusBarUnderTitle()
    }

    func toggleSignalPath() {
        signalPath.view.isHidden.toggle()
        saver.set(\.signalPathVisible, isSignalPathVisible)
    }

    // MARK: Saving the layout

    func windowDidMove(_ notification: Notification) { saveFrame() }

    func windowWillClose(_ notification: Notification) { saveToolbarVisibility() }

    func windowDidResize(_ notification: Notification) { saveFrame() }

    private func saveFrame() {
        guard !restoring else { return }
        let frame = window.frame
        saver.set(
            \.windowFrame,
            WindowFrame(
                x: frame.minX, y: frame.minY, width: frame.width, height: frame.height))
    }
}

/// A window where Esc that no view takes does nothing. AppKit would beep, which flashes the
/// screen when the system's "Flash the screen when an alert sound occurs" is on.
class SilentEscapeWindow: NSWindow {
    override func keyDown(with event: NSEvent) {
        if KeyChord(event: event) == KeyChord(.escape) { return }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {}
}

/// The saved frame, unless no screen in `screens` (their visible frames) shows any of it, as when
/// the display it was on is gone. Nil means center the window.
func restoredFrame(_ saved: WindowFrame?, screens: [NSRect]) -> NSRect? {
    guard let saved else { return nil }
    let frame = NSRect(x: saved.x, y: saved.y, width: saved.width, height: saved.height)
    return screens.contains { $0.intersects(frame) } ? frame : nil
}

/// A visibility saved only when it differs from the one saved last, so each of several places
/// that save it can call it freely.
struct SavedVisibility {
    private(set) var saved: Bool

    init(_ saved: Bool) { self.saved = saved }

    /// Records `visible` and says whether it needs saving.
    mutating func change(to visible: Bool) -> Bool {
        guard visible != saved else { return false }
        saved = visible
        return true
    }
}
