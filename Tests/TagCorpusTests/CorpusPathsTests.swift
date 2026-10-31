import Foundation
import Testing

@testable import TagCorpus

@Test func writesGoOnlyToTheClonesAndTheTempDirectory() throws {
    let roots = try writableRoots()
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("corpus-\(UUID())")
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }
    try requireCorpusWrite(temp.appendingPathComponent("a.m4a").path, roots: roots)
    try requireCorpusWrite(roots[0].appendingPathComponent("Artist/a.m4a").path, roots: roots)

    let link = temp.appendingPathComponent("reference")
    try FileManager.default.createSymbolicLink(
        atPath: link.path, withDestinationPath: referenceCorpusPath)
    for refused in [
        referenceCorpusPath + "/Vladislav Delay/Anima/01 Anima.m4a",
        "/Volumes/music/library/a.flac",
        NSHomeDirectory() + "/Music/a.mp3",
        temp.path + "/../../../../.." + NSHomeDirectory() + "/Music/a.mp3",
        link.appendingPathComponent("Vladislav Delay/Anima/01 Anima.m4a").path,
        roots[0].path,
        roots[0].path + "-elsewhere/a.m4a",
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
