import Foundation
import Testing

@testable import FailureDrill

/// A folder the drill may use, in the temp directory.
private let home = FileManager.default.temporaryDirectory.appendingPathComponent("drill").path

private func problem(_ arguments: [String]) -> String? {
    do {
        _ = try DrillCommand(arguments)
        return nil
    } catch {
        return "\(error)"
    }
}

@Test func aFlagWithoutAFolderFailsLoudly() {
    #expect(problem(["verify", "--home"]) == "--home needs a folder")
    #expect(problem(["verify", "--home", "--scan"]) == "--home needs a folder")
}

@Test func unknownAndRepeatedFlagsFailLoudly() {
    #expect(
        problem(["verify", "--home", home, "--tags", home]) == "--tags isn't an option of verify")
    #expect(problem(["verify", "--bogus", home]) == "--bogus isn't an option of verify")
    #expect(problem(["verify", "--home", home, "--home", home]) == "--home is given twice")
    #expect(problem(["run", "scan", "--home", home]) == "run needs --scan")
    #expect(problem(["run", "--home", home])?.hasPrefix("run needs an operation") == true)
    #expect(problem(["bogus"]) == "bogus isn't a command")
    #expect(problem(["verify", "--home", home]) == nil)
}

@Test func theDrillWritesOnlyUnderTheCachesAndTheTempDirectory() throws {
    #expect(throws: DrillError.self) { try drillFolder("/Volumes/music/library") }
    #expect(throws: DrillError.self) { try drillFolder("/tmp/drill") }
    #expect(throws: DrillError.self) { try drillFolder(home + "/../../../../Users") }
    let caches = try FileManager.default.url(
        for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
    #expect(throws: DrillError.self) {
        try drillFolder(caches.appendingPathComponent("MusicPlayer/../Other").path)
    }
    #expect(try drillFolder(home + "/a").lastPathComponent == "a")
}
