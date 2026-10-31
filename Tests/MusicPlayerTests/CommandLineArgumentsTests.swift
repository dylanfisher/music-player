import Testing

@testable import MusicPlayer

@Test func aFlagFollowedByAnotherHasNoValue() {
    #expect(value(after: "--db", in: ["--scan", "/m", "--db", "--readers", "4"]) == nil)
    #expect(value(after: "--db", in: ["--scan", "/m", "--db", "/x.sqlite"]) == "/x.sqlite")
    #expect(
        argumentProblem(["--scan", "/m", "--db", "--readers", "4"]) == "--db needs a database file")
}

@Test func unknownOptionsFailLoudly() {
    #expect(argumentProblem(["--scna", "/m"]) == "--scna isn't an option")
    #expect(argumentProblem(["--settings", "/s.json", "--measure-window"]) == nil)
    #expect(argumentProblem(["--home", "/tmp/h", "--scan", "/m"]) == nil)
    #expect(argumentProblem(["--home"]) == "--home needs a folder")
    #expect(argumentProblem(["--home", "--measure-window"]) == "--home needs a folder")
    #expect(argumentProblem(["--home", "--x"]) == "--x isn't an option")
    #expect(
        argumentProblem(["--export-settings", "/x.json"]) == "--export-settings isn't an option")
    // macOS adds single-dash arguments of its own when it launches an app.
    #expect(argumentProblem(["-NSDocumentRevisionsDebugMode", "YES"]) == nil)
}

@Test func windowOptionsDontGoWithACommandLineMode() {
    #expect(
        argumentProblem(["--scan", "/m", "--measure-window"])
            == "--measure-window is for the window, so it can't go with --scan")
    #expect(
        argumentProblem(["--snapshot", "/s.png", "--list-devices"])
            == "--snapshot is for the window, so it can't go with --list-devices")
    #expect(argumentProblem(["--readers", "4"]) == "--readers only goes with --scan")
}

@Test func aSnapshotTargetNeedsASnapshotAndAKnownWindow() {
    #expect(argumentProblem(["--snapshot", "/s.png", "--snapshot-of", "palette"]) == nil)
    #expect(
        argumentProblem(["--snapshot", "/s.png", "--snapshot-of"])
            == "--snapshot-of needs main, palette, playlist, settings, shortcuts")
    #expect(
        argumentProblem(["--snapshot", "/s.png", "--snapshot-of", "--measure-window"])
            == "--snapshot-of needs main, palette, playlist, settings, shortcuts")
    #expect(
        argumentProblem(["--snapshot", "/s.png", "--snapshot-of", "queue"])
            == "--snapshot-of needs one of main, palette, playlist, settings, shortcuts, not queue")
    #expect(
        argumentProblem(["--snapshot-of", "palette"]) == "--snapshot-of only goes with --snapshot")
}
