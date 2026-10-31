import Foundation
import Testing

@testable import Log

@Test func categoryIsTheModuleName() {
    #expect(category(fileID: "Playback/PlayFile.swift") == "Playback")
    #expect(category(fileID: #fileID) == "LogTests")
}

/// `scripts/bundle` pulls the identifier out of the source with this pattern, so a reformat that
/// breaks it fails here rather than producing an app without a bundle ID.
@Test func bundleScriptCanReadTheIdentifier() throws {
    let source = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/Core/Log/ModuleLogger.swift")
    let line = "public let bundleIdentifier = \"\(bundleIdentifier)\""
    #expect(try String(contentsOf: source, encoding: .utf8).contains("\n\(line)\n"))
}
