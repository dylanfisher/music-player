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

/// Counts each time a key of the objects it watches is set, even to the value it had. AppKit
/// marks a view as needing display only in an app that draws, so the tests count the sets.
private final class Sets: NSObject {
    private(set) var count = 0
    private var watched: [(NSObject, String)] = []

    init(of key: String, on objects: [NSObject]) {
        super.init()
        for object in objects {
            object.addObserver(self, forKeyPath: key, options: [], context: nil)
            watched.append((object, key))
        }
    }

    deinit {
        for (object, key) in watched { object.removeObserver(self, forKeyPath: key) }
    }

    override func observeValue(
        forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) { count += 1 }
}

/// The position ticks twice a second, so a move of less than a pixel draws nothing.
@MainActor @Test func theBarRedrawsOnlyWhenThePlayedPartMovesAPixel() {
    let (bar, _) = bar()
    bar.fraction = 0.5
    let redraws = Sets(of: "needsDisplay", on: [bar])
    bar.fraction = 0.5 + 0.1 / bar.bounds.width
    #expect(redraws.count == 0)
    bar.fraction = 0.5 + 2 / bar.bounds.width
    #expect(redraws.count == 1)
    bar.fraction = 0
    #expect(redraws.count == 2)
}

/// Times shown again unchanged, as most ticks show them, leave the labels as they are.
@MainActor @Test func timesShownAgainUnchangedArentSetAgain() throws {
    let box = SeekBox(frame: NSRect(x: 0, y: 0, width: 300, height: SeekBox.heightPoints))
    box.showTimes(elapsed: "1:10", total: "3:20")
    let labels = box.subviews.compactMap { $0 as? NSTextField }
    try #require(labels.count == 2)
    let sets = Sets(of: "stringValue", on: labels)
    box.showTimes(elapsed: "1:10", total: "3:20")
    #expect(sets.count == 0)
    box.showTimes(elapsed: "1:11", total: "3:20")
    #expect(sets.count == 1)
    #expect(box.times == ("1:11", "3:20"))
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

/// The box around the bar is lighter than the toolbar under it, with no border, as Swinsian's
/// is: 250 on its 242 toolbar in light, and a step lighter in dark.
@MainActor @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
func theSeekBoxIsLighterThanTheToolbar(_ appearance: NSAppearance.Name) throws {
    let dark = appearance == .darkAqua
    let toolbar = NSBox(frame: NSRect(x: 0, y: 0, width: 320, height: 40))
    toolbar.boxType = .custom
    toolbar.borderWidth = 0
    toolbar.titlePosition = .noTitle
    toolbar.contentViewMargins = .zero
    let swinsianToolbar = 242.0 / 255
    toolbar.fillColor =
        dark
        ? .windowBackgroundColor
        : NSColor(srgbRed: swinsianToolbar, green: swinsianToolbar, blue: swinsianToolbar, alpha: 1)
    toolbar.appearance = NSAppearance(named: appearance)
    let box = SeekBox(frame: NSRect(x: 10, y: 11, width: 300, height: SeekBox.heightPoints))
    box.showTimes(elapsed: "1:10", total: "3:20")
    toolbar.addSubview(box)
    toolbar.layoutSubtreeIfNeeded()
    let image = try #require(toolbar.bitmapImageRepForCachingDisplay(in: toolbar.bounds))
    toolbar.cacheDisplay(in: toolbar.bounds, to: image)
    let scale = Double(image.pixelsWide) / toolbar.bounds.width
    func gray(atX x: Double, y: Double) throws -> Double {
        let color = try #require(
            image.colorAt(x: Int(x * scale), y: Int((toolbar.bounds.height - y) * scale))?
                .usingColorSpace(.sRGB))
        return color.greenComponent * 255
    }
    let under = try gray(atX: 5, y: 20)
    // Inside the box before the elapsed time, and on its edge, where a border would be.
    let inside = try gray(atX: 13, y: 20)
    let edge = try gray(atX: 10.25, y: 20)
    if dark {
        #expect(inside - under > 4 && inside - under < 20, "\(inside) on \(under)")
    } else {
        #expect(abs(inside - 250) < 2, "\(inside) on \(under)")
    }
    #expect(edge >= under - 1, "\(edge) on \(under)")
}
