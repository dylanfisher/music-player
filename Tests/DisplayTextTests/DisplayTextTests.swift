import AppKit
import Testing

@testable import DisplayText

@Test func clockShowsMinutesAndSecondsAndHoursOnlyWhenThereAreSome() {
    #expect(clock(312.4) == "5:12")
    #expect(clock(5) == "0:05")
    #expect(clock(3725) == "1:02:05")
    #expect(clock(-3) == "0:00")
}

@Test(arguments: [
    (44_100.0, "44.1"), (96_000.0, "96"), (705_600.0, "705.6"), (768_000.0, "768"),
])
func formatsKilohertz(hertz: Double, expected: String) {
    #expect(kilohertz(hertz) == expected)
}

@Test func bitDepthReadsTheSameForAnyIntegerType() {
    #expect(bitDepth(24) == "24-bit")
    #expect(bitDepth(UInt32(32)) == "32-bit")
}

@Test func aFormatReadsAsItsRateAndDepth() {
    #expect(formatText(rateHz: 44_100, bits: 16, isFloat: false) == "44.1 kHz · 16-bit")
    #expect(formatText(rateHz: 48_000, bits: 32, isFloat: true) == "48 kHz · 32-bit float")
    #expect(formatText(rateHz: 44_100, bits: nil, isFloat: false) == "44.1 kHz")
}

@Test func controlCharactersAreEscapedForTheTerminal() {
    for value in Array(0x00..<0x20) + Array(0x7F...0x9F) {
        let scalar = Unicode.Scalar(value)!
        let escaped = terminalSafe("a" + String(Character(scalar)) + "b")
        #expect(escaped == "a\\u{\(String(value, radix: 16, uppercase: true))}b", "\(value)")
    }
    #expect(terminalSafe("\u{1B}]52;c;aGk=\u{07}") == "\\u{1B}]52;c;aGk=\\u{7}")
    #expect(
        terminalSafe("a.flac\nscanned 0 files\r\t") == "a.flac\\u{A}scanned 0 files\\u{D}\\u{9}")
    let plain = "Björk – Jóga, live side A ★ \u{202E}"
    #expect(terminalSafe(plain) == plain)
}

@MainActor @Test func theMarkedRowIsTintedGrayNotBlue() throws {
    let row = MarkedRowView(frame: NSRect(x: 0, y: 0, width: 40, height: 18))
    row.appearance = NSAppearance(named: .aqua)
    row.isMarked = true
    let bitmap = try #require(row.bitmapImageRepForCachingDisplay(in: row.bounds))
    row.cacheDisplay(in: row.bounds, to: bitmap)
    // Past the bar at the leading edge.
    let color = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2))
    let rgb = try #require(color.usingColorSpace(.sRGB))
    #expect(rgb.alphaComponent > 0)
    #expect(abs(rgb.redComponent - rgb.blueComponent) < 0.03)
    #expect(abs(rgb.greenComponent - rgb.blueComponent) < 0.03)
}
