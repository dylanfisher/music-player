import AppKit
import Testing

@testable import NowPlaying

@MainActor
private func bar() -> (SeekBar, () -> [(Double, Bool)]) {
    let bar = SeekBar(frame: NSRect(x: 0, y: 0, width: 200, height: SeekBar.heightPoints))
    var seeks: [(Double, Bool)] = []
    bar.seek = { seeks.append(($0, $1)) }
    return (bar, { seeks })
}

@Test func fractionIsHeldInsideTheBar() {
    #expect(SeekBar.fraction(atX: 50, width: 200) == 0.25)
    #expect(SeekBar.fraction(atX: -10, width: 200) == 0)
    #expect(SeekBar.fraction(atX: 250, width: 200) == 1)
    #expect(SeekBar.fraction(atX: 10, width: 0) == 0)
}

@MainActor @Test func aClickMovesThePlayheadAndSeeksAtOnce() {
    let (bar, seeks) = bar()
    bar.press(atX: 150)
    #expect(bar.fraction == 0.75)
    #expect(seeks().map(\.0) == [0.75])
    #expect(seeks().map(\.1) == [true])
    bar.release()
    #expect(seeks().count == 1)
    #expect(!bar.isTracking)
}

@MainActor @Test func aDragFollowsThePointerAndSeeksWhereItEnds() {
    let (bar, seeks) = bar()
    bar.press(atX: 20)
    bar.drag(toX: 100)
    #expect(bar.isTracking)
    bar.drag(toX: 180)
    bar.release()
    #expect(seeks().map(\.0) == [0.1, 0.5, 0.9, 0.9])
    #expect(seeks().map(\.1) == [true, false, false, true])
}

@MainActor @Test func aDisabledBarIgnoresTheMouse() {
    let (bar, seeks) = bar()
    bar.isEnabled = false
    bar.press(atX: 100)
    bar.drag(toX: 150)
    bar.release()
    #expect(seeks().isEmpty)
    #expect(bar.fraction == 0)
}

@MainActor @Test func disablingOrLeavingTheWindowLetsGoWithoutSeeking() {
    let (bar, seeks) = bar()
    bar.press(atX: 20)
    bar.drag(toX: 60)
    bar.isEnabled = false
    bar.release()
    bar.isEnabled = true
    bar.press(atX: 20)
    bar.drag(toX: 60)
    bar.viewDidMoveToWindow()
    bar.release()
    #expect(seeks().map(\.1) == [true, false, true, false])
}

/// The track and the played part are Swinsian's colors, the same in light and dark.
@MainActor @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
func theBarDrawsSwinsiansColors(_ appearance: NSAppearance.Name) throws {
    let (bar, _) = bar()
    bar.fraction = 0.5
    bar.appearance = NSAppearance(named: appearance)
    let image = try #require(bar.bitmapImageRepForCachingDisplay(in: bar.bounds))
    bar.cacheDisplay(in: bar.bounds, to: image)
    let scale = Double(image.pixelsWide) / bar.bounds.width
    func pixel(atX x: Double) throws -> NSColor {
        try #require(
            image.colorAt(x: Int(x * scale), y: image.pixelsHigh / 2)?.usingColorSpace(.sRGB))
    }
    func matches(_ drawn: NSColor, _ expected: NSColor) throws -> Bool {
        let expected = try #require(expected.usingColorSpace(.sRGB))
        return [
            drawn.redComponent - expected.redComponent,
            drawn.greenComponent - expected.greenComponent,
            drawn.blueComponent - expected.blueComponent,
        ].allSatisfy { abs($0) < 0.02 }
    }
    let track = try pixel(atX: 150)
    let played = try pixel(atX: 50)
    #expect(try matches(track, SeekBar.trackColor), "\(track)")
    #expect(try matches(played, SeekBar.playedColor), "\(played)")
    #expect(
        SeekBar.playedColor
            == (NSColor.currentControlTint == .graphiteControlTint ? .darkGray : SeekBar.playedBlue)
    )
}
