import AppKit
import Testing

@testable import WindowPlacement

/// Two screens side by side, the primary on the left, as their visible frames.
private let primary = CGRect(x: 0, y: 0, width: 1440, height: 875)
private let secondary = CGRect(x: 1440, y: 0, width: 1920, height: 1055)

@Test func aSavedFrameOnAScreenIsKept() {
    let saved = CGRect(x: 1600, y: 200, width: 900, height: 500)
    #expect(
        placedFrame(
            saved: saved, size: CGSize(width: 400, height: 300), resizable: true,
            screens: [primary, secondary], anchorScreen: primary) == saved)
}

/// A window its content sizes, as Settings is, keeps that size under the saved top left.
@Test func aWindowThatDoesntResizeKeepsItsSizeUnderTheSavedTopLeft() {
    let saved = CGRect(x: 1600, y: 200, width: 640, height: 500)
    #expect(
        placedFrame(
            saved: saved, size: CGSize(width: 640, height: 300), resizable: false,
            screens: [primary, secondary], anchorScreen: primary)
            == CGRect(x: 1600, y: 400, width: 640, height: 300))
}

/// Opened the first time, or saved on a display that's gone, a window is centered on the
/// anchor's screen, the main window's, not the primary.
@Test func aWindowWithNoFrameOnScreenIsCenteredOnTheAnchorsScreen() {
    let size = CGSize(width: 1100, height: 480)
    let centered = CGRect(x: 1850, y: 288, width: 1100, height: 480)
    #expect(
        placedFrame(
            saved: nil, size: size, resizable: true, screens: [primary, secondary],
            anchorScreen: secondary) == centered)
    #expect(
        placedFrame(
            saved: CGRect(x: 4000, y: 0, width: 1100, height: 480), size: size, resizable: true,
            screens: [primary, secondary], anchorScreen: secondary) == centered)
    // Shrunk to a short screen when it can be.
    let short = CGRect(x: 0, y: 0, width: 1280, height: 400)
    #expect(
        placedFrame(saved: nil, size: size, resizable: true, screens: [short], anchorScreen: short)
            == CGRect(x: 90, y: 0, width: 1100, height: 400))
}

/// A window opened the first time is centered on its anchor's screen, the last screen here, and
/// a later launch opens it where it was moved to.
@MainActor @Test func aPlacedWindowSavesItsFrameAndOpensThereNextTime() throws {
    func window(on screen: CGRect? = nil) -> NSWindow {
        let size = CGSize(width: 300, height: 200)
        let origin = screen.map { CGPoint(x: $0.midX, y: $0.midY) } ?? .zero
        return NSWindow(
            contentRect: NSRect(origin: origin, size: size), styleMask: [.titled, .resizable],
            backing: .buffered, defer: true)
    }
    let anchor = window(on: try #require(NSScreen.screens.last?.visibleFrame))
    let screen = try #require(anchor.screen?.visibleFrame)
    let placed = PlacedWindows()
    placed.anchor = { anchor }
    var saves: [[String: CGRect]] = []
    placed.framesChanged = { saves.append($0) }
    let first = window()
    placed.place(first, as: "Test")
    let size = first.frame.size
    #expect(abs(first.frame.midX - screen.midX) <= 1 && abs(first.frame.midY - screen.midY) <= 1)

    let moved = NSRect(
        x: screen.minX + 10, y: screen.minY + 20, width: size.width + 50, height: size.height)
    first.setFrame(moved, display: false)
    #expect(saves.last == ["Test": moved])

    let next = PlacedWindows()
    next.frames = try #require(saves.last)
    let second = window()
    next.place(second, as: "Test")
    #expect(second.frame == moved)
}
