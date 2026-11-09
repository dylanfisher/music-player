import AppKit
import Foundation
import Settings
import Testing

@testable import Fixtures
@testable import Library
@testable import LibraryBrowser

/// A browser in a window, and a temporary library folder holding a copy of a fixture file
/// whose tags read, at a path that isn't its layout's, and one more file outside it.
@MainActor
private func organizingBrowser() throws -> (
    LibraryBrowser, NSWindow, library: String, inside: String, outside: String
) {
    let databaseURL = try writableBrowserDatabase()
    let browser = LibraryBrowser(
        reader: try LibraryReader(databaseURL: databaseURL),
        index: try LibraryIndex(at: databaseURL), layout: AppState().trackTable.defaultValue,
        browserHeight: 100, groupByAlbumArtist: false, thumbnails: nil)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled],
        backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = browser.content.view
    let source = try browserLibrary.get().root
    let fixture = try #require(
        try loadManifest(in: URL(fileURLWithPath: source, isDirectory: true)).files.first {
            $0.malformation == nil && $0.tags?.title != nil && $0.container == .flac
        })
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("organizing-\(UUID().uuidString)").resolvingSymlinksInPath().path
    let library = root + "/Library"
    try FileManager.default.createDirectory(
        atPath: library + "/Loose", withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        atPath: root + "/Elsewhere", withIntermediateDirectories: true)
    let inside = library + "/Loose/misnamed.flac"
    let outside = root + "/Elsewhere/outside.flac"
    try FileManager.default.copyItem(atPath: source + "/" + fixture.path, toPath: inside)
    try FileManager.default.copyItem(atPath: source + "/" + fixture.path, toPath: outside)
    return (browser, window, library, inside, outside)
}

/// What the question was asked about, which its closure can't capture as a var.
@MainActor
private final class Asked {
    var plans: [FilesOrganized] = []
    var organized: [[String]] = []
}

@MainActor @Test func organizeSelectedFilesAsksWithTheCountThatWillMoveAndSkipsTheRest()
    async throws
{
    let (browser, window, library, inside, outside) = try organizingBrowser()
    let asked = Asked()
    for answer in [false, true] {
        browser.confirmOrganizing = { plan, _, reply in
            asked.plans.append(plan)
            reply(answer)
        }
        await browser.organizeFiles([inside, outside], in: library, over: window) { paths, _ in
            asked.organized.append(paths)
        }
    }
    let plan = try #require(asked.plans.first)
    #expect(plan.moved.map(\.from) == [inside])
    #expect(plan.outside == [outside])
    let question = organizeQuestion(plan)
    #expect(question.message == "Organize 1 File?")
    #expect(question.detail.contains("1 not in the library folder"))
    // Cancel organizes nothing; Organize hands every selected path on, to be checked again.
    #expect(asked.organized == [[inside, outside]])
    // Asking renames nothing.
    #expect(FileManager.default.fileExists(atPath: inside))
}

@MainActor @Test func organizeSelectedFilesWithNothingToMoveAsksNothing() async throws {
    let (browser, window, library, _, outside) = try organizingBrowser()
    browser.confirmOrganizing = { _, _, _ in Issue.record("asked with nothing to move") }
    await browser.organizeFiles([outside], in: library, over: window) { _, _ in
        Issue.record("organized with nothing to move")
    }
    #expect(browser.status.organizedReport.map(\.line).first?.contains(outside) == true)
    await browser.organizeFiles([outside], in: nil, over: window) { _, _ in
        Issue.record("organized with no library folder")
    }
}

@MainActor @Test func whatWasntMovedIsListedInTheProblemsWindow() throws {
    let (browser, _, _, _, _) = try organizingBrowser()
    var organized = FilesOrganized()
    organized.moved = [TrackMove(from: "/l/a.flac", to: "/l/A/a.flac")]
    organized.problems = ["/l/b.flac: not moved, /l/A/b.flac is already there"]
    browser.finishOrganizing(organized, carried: nil, failure: "the index is locked")
    #expect(
        browser.status.organizedReport.map(\.line) == [
            "/l/b.flac: not moved, /l/A/b.flac is already there",
            "the stats didn't follow the moved files: the index is locked",
        ])
    #expect(browser.status.problemLines.contains(browser.status.organizedReport[0].line))
}
