import AppKit
import Testing

@testable import LibraryBrowser
@testable import MusicPlayer
@testable import NowPlaying
@testable import Playback
@testable import Settings

/// On glass the window has a full-size content view, and AppKit centers the title over the
/// area beside the sidebar, so the bar's middle centers there; off glass, on the whole window,
/// and with the sidebar hidden, on the whole window either way (ADR 0085).
@MainActor @Test(arguments: [false, true])
func theStatusBarsMiddleCentersUnderTheTitle(_ glass: Bool) async throws {
    let fixture = try await MainWindowFixture(glass: glass)
    defer { fixture.close() }
    let window = fixture.window.window
    #expect(window.styleMask.contains(.fullSizeContentView) == glass)
    let content = try #require(window.contentView)
    let middle = try #require(fixture.browser.statusColumn(at: .center))
    func midX(_ view: NSView) -> CGFloat {
        window.layoutIfNeeded()
        return view.convert(view.bounds, to: nil).midX
    }
    let sidebar = fixture.browser.sidebar.view
    let besideSidebar = (sidebar.convert(sidebar.bounds, to: nil).maxX + content.bounds.maxX) / 2
    #expect(abs(midX(middle) - (glass ? besideSidebar : content.bounds.midX)) <= 0.5)
    fixture.window.toggleSidebar()
    #expect(abs(midX(middle) - content.bounds.midX) <= 0.5)
    fixture.window.toggleSidebar()
    fixture.window.setGlass(!glass)
    let sidebarEdge = sidebar.convert(sidebar.bounds, to: nil).maxX
    #expect(
        abs(midX(middle) - (glass ? content.bounds.midX : (sidebarEdge + content.bounds.maxX) / 2))
            <= 0.5)
}

/// On glass with the sidebar hidden and the queue shown, the middle is on the window's center:
/// the area beside the sidebar is the whole window, the queue included.
@MainActor @Test func onGlassWithoutTheSidebarTheMiddleIsOnTheWindowsCenter() async throws {
    let fixture = try await MainWindowFixture(glass: true)
    defer { fixture.close() }
    let window = fixture.window
    if !window.isQueueVisible { window.toggleQueue() }
    if window.isSidebarVisible { window.toggleSidebar() }
    window.window.layoutIfNeeded()
    let content = try #require(window.window.contentView)
    let middle = try #require(fixture.browser.statusColumn(at: .center))
    #expect(window.isQueueVisible && !window.isSidebarVisible)
    #expect(abs(middle.convert(middle.bounds, to: nil).midX - content.bounds.midX) <= 0.5)
}

/// The window's title is the playing track's, by `appearance.windowTitle`, and the app's name
/// with nothing playing; it shows over the toolbar glass on and off.
@MainActor @Test(arguments: [false, true])
func theWindowIsTitledByThePlayingTrack(_ glass: Bool) async throws {
    let fixture = try await MainWindowFixture(glass: glass)
    defer { fixture.close() }
    let window = fixture.window.window
    #expect(window.title == appName)
    var state = PlaybackState()
    state.queue = [URL(fileURLWithPath: "/m/Come Together.flac", isDirectory: false)]
    state.order = [0]
    state.currentIndex = 0
    state.status = .playing
    fixture.nowPlaying.apply(PlaybackUpdate(state: state, event: .trackStarted(index: 0)))
    #expect(window.title == "Come Together")
    #expect(window.titleVisibility == .visible)
    fixture.window.setGlass(!glass)
    #expect(window.title == "Come Together" && window.titleVisibility == .visible)
    fixture.nowPlaying.windowTitle = WindowTitle("♪ {title}")
    #expect(window.title == "♪ Come Together")
    state.currentIndex = nil
    fixture.nowPlaying.apply(PlaybackUpdate(state: state, event: .stopped))
    #expect(window.title == appName)
}
