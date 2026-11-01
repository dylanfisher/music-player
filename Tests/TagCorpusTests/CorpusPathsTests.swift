import Foundation
import Testing

@testable import TagCorpus

@Test func writesGoOnlyUnderTheRoots() throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("corpus-\(UUID())")
    let clones = temp.appendingPathComponent("clones")
    let elsewhere = temp.appendingPathComponent("clones-elsewhere")
    for folder in [clones.appendingPathComponent("Artist"), elsewhere] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    defer { try? FileManager.default.removeItem(at: temp) }
    let roots = [clones]
    try requireCorpusWrite(clones.appendingPathComponent("a.m4a").path, roots: roots)
    try requireCorpusWrite(clones.appendingPathComponent("Artist/a.m4a").path, roots: roots)
    #expect(try writableRoots().contains(FileManager.default.temporaryDirectory))

    let link = clones.appendingPathComponent("reference")
    try FileManager.default.createSymbolicLink(
        atPath: link.path, withDestinationPath: referenceCorpusPath)
    for refused in [
        referenceCorpusPath + "/Vladislav Delay/Anima/01 Anima.m4a",
        "/Volumes/music/library/a.flac",
        NSHomeDirectory() + "/Music/a.mp3",
        clones.path + "/../../../../../.." + NSHomeDirectory() + "/Music/a.mp3",
        link.appendingPathComponent("Vladislav Delay/Anima/01 Anima.m4a").path,
        clones.path,
        elsewhere.appendingPathComponent("a.m4a").path,
    ] {
        #expect(throws: CorpusError.self, "\(refused)") {
            try requireCorpusWrite(refused, roots: roots)
        }
    }
}

@Test func theReferenceIsFoundFromTheHomeFolder() {
    #expect(referenceCorpusPath == NSHomeDirectory() + "/Music/music-player/test")
}

@Test func danglingLinksAndMissingFoldersAreRefused() throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("corpus-\(UUID())")
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }
    let roots = try writableRoots()
    let dangling = temp.appendingPathComponent("dangling.m4a")
    try FileManager.default.createSymbolicLink(
        atPath: dangling.path, withDestinationPath: temp.appendingPathComponent("gone").path)
    let danglingFolder = temp.appendingPathComponent("folder")
    try FileManager.default.createSymbolicLink(
        atPath: danglingFolder.path, withDestinationPath: "/nowhere/at/all")
    for refused in [
        dangling.path, danglingFolder.appendingPathComponent("a.m4a").path,
        temp.appendingPathComponent("missing/a.m4a").path,
    ] {
        #expect(throws: CorpusError.self, "\(refused)") {
            try requireCorpusWrite(refused, roots: roots)
        }
    }
}

@Test func theToolsFlagsAreChecked() {
    #expect(argumentProblem([]) == nil)
    #expect(argumentProblem(["/some/folder"]) == nil)
    #expect(argumentProblem(["--round-trip"]) == nil)
    #expect(argumentProblem(["--round-trip", "--full-disk", "/mnt"]) == nil)
    #expect(argumentProblem(["--paths"]) == nil)
    #expect(argumentProblem(["--round-trip", "--full-disk"]) != nil)
    #expect(argumentProblem(["--round-trip", "--full-disk", "--paths"]) != nil)
    #expect(argumentProblem(["--full-disk", "/mnt"]) != nil)
    #expect(argumentProblem(["--write", "/x"]) != nil)
    #expect(argumentProblem(["a", "b"]) != nil)
}
