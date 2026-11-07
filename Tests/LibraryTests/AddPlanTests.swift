import Foundation
import Testing

@testable import Library

/// A temporary folder holding `files`, by relative path, each a few bytes; nothing reads them
/// as audio. Returns its path.
private func folder(_ files: [String]) throws -> String {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("add-plan-\(UUID().uuidString)")
    for file in files {
        let url = root.appendingPathComponent(file)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }
    // The temporary folder is under /var, a symbolic link; the drop's paths are resolved.
    return URL(fileURLWithPath: root.path, isDirectory: true).resolvingSymlinksInPath().path
}

@Test func dropsInAWatchedFolderAreRescannedAndOthersWatchTheirFolder() throws {
    let root = try folder([
        "Music/A/1.flac", "Music/A/B/2.mp3", "Downloads/x/3.m4a", "Downloads/y/4.flac",
        "Downloads/notes.txt", "Elsewhere/Album/5.flac",
    ])
    let plan = try planAdding(
        [
            "\(root)/Music/A/1.flac", "\(root)/Music/A/B", "\(root)/Downloads/x/3.m4a",
            "\(root)/Downloads/y/4.flac", "\(root)/Downloads/notes.txt",
            "\(root)/Elsewhere/Album",
        ],
        watched: ["\(root)/Music"], libraryFolder: nil)
    // The dropped folder B is under A, which is rescanned whole.
    #expect(plan.directoriesToRescan == ["\(root)/Music/A"])
    #expect(
        plan.foldersToWatch == [
            "\(root)/Downloads/x", "\(root)/Downloads/y", "\(root)/Elsewhere/Album",
        ])
    #expect(plan.filesToCopy.isEmpty)
    #expect(plan.problems.isEmpty)
}

@Test func aFolderDroppedOverAnotherDroppedOneIsWatchedOnce() throws {
    let root = try folder(["In/a.flac", "In/Sub/b.flac"])
    let plan = try planAdding(
        ["\(root)/In/Sub/b.flac", "\(root)/In"], watched: [], libraryFolder: nil)
    #expect(plan.foldersToWatch == ["\(root)/In"])
}

@Test func withALibraryFolderFilesFromOutsideItAreCopiedAndItIsWatched() throws {
    let root = try folder([
        "Library/Old/1.flac", "Incoming/2.flac", "Incoming/Disc/3.mp3", "Incoming/Disc/.4.flac",
        "Incoming/Disc/cover.jpg",
    ])
    let library = "\(root)/Library"
    let plan = try planAdding(
        ["\(root)/Library/Old/1.flac", "\(root)/Incoming"], watched: [], libraryFolder: library)
    #expect(plan.filesToCopy == ["\(root)/Incoming/2.flac", "\(root)/Incoming/Disc/3.mp3"])
    // The file already in the library folder is in it once it's watched.
    #expect(plan.foldersToWatch == [library])
    #expect(plan.directoriesToRescan.isEmpty)
    #expect(plan.directoriesToRescan(afterCopyingTo: ["\(library)/A/B/2.flac"]).isEmpty)
}

@Test func aWatchedLibraryFolderIsRescannedWhereTheCopiesWent() throws {
    let root = try folder(["Music/Library/Old/1.flac", "Incoming/2.flac"])
    let library = "\(root)/Music/Library"
    let plan = try planAdding(
        ["\(root)/Music/Library/Old/1.flac", "\(root)/Incoming/2.flac"],
        watched: ["\(root)/Music"], libraryFolder: library)
    #expect(plan.filesToCopy == ["\(root)/Incoming/2.flac"])
    #expect(plan.foldersToWatch.isEmpty)
    #expect(plan.directoriesToRescan == ["\(library)/Old"])
    #expect(
        plan.directoriesToRescan(afterCopyingTo: ["\(library)/A/B/2.flac", "\(library)/A/B/3.flac"])
            == ["\(library)/A/B"])
}

@Test func aLibraryFolderThatIsntThereFailsTheDrop() throws {
    let root = try folder(["Incoming/2.flac"])
    #expect(throws: AddError.libraryFolderMissing("\(root)/Gone")) {
        try planAdding(
            ["\(root)/Incoming/2.flac"], watched: [], libraryFolder: "\(root)/Gone")
    }
    #expect(throws: AddError.libraryFolderNotAbsolute("Music")) {
        try planAdding(["\(root)/Incoming/2.flac"], watched: [], libraryFolder: "Music")
    }
}

@Test func aDroppedPathThatIsGoneIsAProblem() throws {
    let root = try folder([])
    let plan = try planAdding(["\(root)/gone.flac"], watched: [], libraryFolder: nil)
    #expect(plan.isEmpty)
    #expect(plan.problems.count == 1)
    #expect(plan.problems.first?.hasPrefix("\(root)/gone.flac: ") == true)
}
