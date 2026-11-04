import AppKit
import Testing

@testable import LibraryBrowser
@testable import MusicPlayer
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
