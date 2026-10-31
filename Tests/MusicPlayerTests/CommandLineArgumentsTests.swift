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
