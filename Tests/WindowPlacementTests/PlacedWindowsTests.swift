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

/// A frame a screen shows only a sliver of, here a pixel, moves onto that screen, title bar and
/// all, rather than opening where it can't be dragged back.
@Test func aFrameBarelyOnAScreenMovesOntoIt() {
    let saved = CGRect(x: 3359, y: 600, width: 900, height: 500)
    #expect(
        placedFrame(
            saved: saved, size: saved.size, resizable: true, screens: [primary, secondary],
            anchorScreen: primary) == CGRect(x: 2460, y: 555, width: 900, height: 500))
    // Above the screen's top by a pixel's overlap, its title bar comes down onto it.
    let above = CGRect(x: 100, y: 874, width: 600, height: 400)
    #expect(
        placedFrame(
            saved: above, size: above.size, resizable: false, screens: [primary],
            anchorScreen: primary) == CGRect(x: 100, y: 475, width: 600, height: 400))
}

/// A resizable window larger than the screen it's on shrinks to fit it.
@Test func aResizableWindowLargerThanItsScreenShrinksToIt() {
    let saved = CGRect(x: -100, y: -50, width: 1600, height: 1000)
    #expect(
        placedFrame(
            saved: saved, size: saved.size, resizable: true, screens: [primary],
            anchorScreen: primary) == primary)
    // One that doesn't resize keeps its size, its top and left edges on the screen.
    #expect(
        placedFrame(
            saved: saved, size: saved.size, resizable: false, screens: [primary],
            anchorScreen: primary) == CGRect(x: 0, y: -125, width: 1600, height: 1000))
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

/// A window opened while another of its kind is open cascades from it at its size, and the
/// frame kept stays the first one's.
@MainActor @Test func aSecondWindowCascadesFromTheLastAndKeepsNoFrame() throws {
    func window(_ size: CGSize) -> NSWindow {
        NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable],
            backing: .buffered, defer: true)
    }
    let first = window(CGSize(width: 400, height: 300))
    first.keepsFrame(as: "Cascade Test", cascadedFrom: nil)
    first.setFrameTopLeftPoint(NSPoint(x: first.frame.minX + 10, y: first.frame.maxY))
    let kept = first.frame
    #expect(PlacedWindows.shared.frames["Cascade Test"] == kept)
    let second = window(CGSize(width: 200, height: 100))
    second.keepsFrame(as: "Cascade Test", cascadedFrom: first)
    #expect(second.frame.size == first.frame.size)
    #expect(second.frame.minX > first.frame.minX)
    #expect(second.frame.maxY < first.frame.maxY)
    second.setFrameTopLeftPoint(NSPoint(x: second.frame.minX + 30, y: second.frame.maxY))
    #expect(PlacedWindows.shared.frames["Cascade Test"] == kept)
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
