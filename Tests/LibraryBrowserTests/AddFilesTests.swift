import AppKit
import Foundation
import Settings
import Testing

@testable import Fixtures
@testable import Library
@testable import LibraryBrowser

/// A browser in a window, so the drop's question has a window to go over, and a temporary
/// folder with an `Incoming` folder holding a copy of a fixture file whose tags read.
@MainActor
private func addingBrowser() throws -> (LibraryBrowser, NSWindow, root: String, file: String) {
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
        .appendingPathComponent("adding-\(UUID().uuidString)").resolvingSymlinksInPath().path
    let incoming = root + "/Incoming"
    try FileManager.default.createDirectory(
        atPath: incoming, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        atPath: root + "/Library", withIntermediateDirectories: true)
    let file = incoming + "/dropped.flac"
    try FileManager.default.copyItem(atPath: source + "/" + fixture.path, toPath: file)
    return (browser, window, root, file)
}

/// The folders a drop asked to watch, which the question's closure can't capture as a var.
@MainActor
private final class Asked {
    var folders: [[String]] = []
}

@MainActor @Test func aFileOutsideTheWatchedFoldersWatchesItsFolderOnceAgreed() async throws {
    let (browser, window, root, file) = try addingBrowser()
    browser.watchedFolders = { [] }
    let asked = Asked()
    browser.confirmAdding = { folders, _, reply in
        asked.folders.append(folders)
        reply(false)
    }
    var watched: [URL] = []
    browser.watch = { watched.append($0) }
    let url = URL(fileURLWithPath: file, isDirectory: false)

    await browser.addFiles([url])
    #expect(asked.folders == [[root + "/Incoming"]])
    #expect(watched.isEmpty)

    browser.confirmAdding = { _, _, reply in reply(true) }
    await browser.addFiles([url])
    #expect(watched == [URL(fileURLWithPath: root + "/Incoming", isDirectory: true)])
    #expect(browser.statusText == "Watching 1 new folder")
    window.close()
}

@MainActor @Test func aFileInAWatchedFolderIsRescannedWithoutAsking() async throws {
    let (browser, window, root, file) = try addingBrowser()
    browser.watchedFolders = { [WatchedFolder(path: root, kind: .local)] }
    browser.confirmAdding = { _, _, _ in Issue.record("asked to watch a watched folder") }
    var rescanned: [[String]] = []
    browser.rescanDirectories = { rescanned.append($0) }

    await browser.addFiles([URL(fileURLWithPath: file, isDirectory: false)])
    #expect(rescanned == [[root + "/Incoming"]])
    window.close()
}

@MainActor @Test func copyingPutsTheFileInTheWatchedLibraryFolderAndRescansThere() async throws {
    let (browser, window, root, file) = try addingBrowser()
    let library = root + "/Library"
    browser.watchedFolders = { [WatchedFolder(path: library, kind: .local)] }
    browser.libraryFolder = { (true, library) }
    browser.confirmAdding = { _, _, _ in Issue.record("asked to watch a watched folder") }
    var rescanned: [String] = []
    browser.rescanDirectories = { rescanned += $0 }

    await browser.addFiles([URL(fileURLWithPath: file, isDirectory: false)])
    let directory = try #require(rescanned.first)
    #expect(rescanned.count == 1)
    #expect(directory.hasPrefix(library + "/"))
    let copies = try FileManager.default.contentsOfDirectory(atPath: directory)
    #expect(copies.count == 1)
    #expect(FileManager.default.fileExists(atPath: file))
    #expect(browser.statusText == "Copied 1 of 1 file into the library folder")
    #expect(browser.status.copyingText == nil)

    // The same file again would land on the copy, so it's refused and listed.
    await browser.addFiles([URL(fileURLWithPath: file, isDirectory: false)])
    #expect(browser.statusText == "Copied 0 of 1 file into the library folder")
    #expect(browser.status.addedFilesReport.map(\.line).first?.contains("is already there") == true)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory).count == 1)
    browser.problems?.window.close()
    window.close()
}

@MainActor @Test func copyingWithNoLibraryFolderSetAddsNothing() async throws {
    let (browser, window, _, file) = try addingBrowser()
    browser.libraryFolder = { (true, nil) }
    browser.confirmAdding = { _, _, _ in Issue.record("asked with no library folder") }
    browser.watch = { _ in Issue.record("watched with no library folder") }

    await browser.addFiles([URL(fileURLWithPath: file, isDirectory: false)])
    #expect(browser.statusText.contains("no library folder is set"))
    window.close()
}

/// A copy into the library folder is listed in the question at quit while it runs (ADR 0191).
@MainActor @Test func aCopyIsUnfinishedWorkWhileItRuns() throws {
    let (browser, window, _, _) = try addingBrowser()
    #expect(browser.unfinishedWork.isEmpty)
    browser.showCopying(("Copying into the library folder: 1 of 2", 0))
    #expect(browser.unfinishedWork == ["Copying into the library folder: 1 of 2"])
    browser.showCopying(nil)
    #expect(browser.unfinishedWork.isEmpty)
    window.close()
}
