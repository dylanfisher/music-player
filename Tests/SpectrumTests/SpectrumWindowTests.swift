import AppKit
import Testing

@testable import Analysis
@testable import Spectrum

@MainActor @Test func eightFilesLeaveTheChartAndTheDifferencesRoomToRead() async throws {
    let types = ["WAV", "FLAC", "AIFF", "M4A", "MP3", "OGG", "WV", "APE"]
    #expect(types.count == AnalysisRules.comparedFiles)
    let model = SpectrumModel(
        files: types.map {
            file(
                "So Many Questions", album: "An Album Title (Deluxe Edition)",
                sizeBytes: 45_158_000, type: $0)
        })
    model.start { path, _ in
        let index = types.firstIndex { path.hasSuffix(".\($0.lowercased())") } ?? 0
        return result(
            rateHz: index.isMultiple(of: 2) ? 44_100 : 96_000,
            cutoffHz: index == 3 ? 16_000 : nil, level: { $0 < 40 ? -30 - Double(index) : -60 })
    }
    await model.finished()
    let controller = SpectrumWindow(model: model)
    let window = try #require(controller.window)
    let content = try #require(window.contentView)
    content.layoutSubtreeIfNeeded()
    #expect(window.frame.height <= 900 - 25, "\(window.frame)")
    #expect(controller.average.frame.height >= 150, "\(controller.average.frame)")
    #expect(controller.differences.frame.height >= 120, "\(controller.differences.frame)")
    let text = try #require(controller.differences.documentView as? NSTextView)
    #expect(text.string.components(separatedBy: "\n\n").count == types.count - 1)
    // A picture of the window for review, under .build.
    let image = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
    content.cacheDisplay(in: content.bounds, to: image)
    let out = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/snapshots/spectrum-window.png")
    try FileManager.default.createDirectory(
        at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
    try #require(image.representation(using: .png, properties: [:])).write(to: out)
    window.close()
}
