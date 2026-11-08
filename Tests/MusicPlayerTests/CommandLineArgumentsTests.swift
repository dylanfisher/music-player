import Foundation
import Testing

@testable import MusicPlayer

@Test func aFlagFollowedByAnotherHasNoValue() {
    #expect(value(after: .db, in: ["--scan", "/m", "--db", "--readers", "4"]) == nil)
    #expect(value(after: .db, in: ["--scan", "/m", "--db", "/x.sqlite"]) == "/x.sqlite")
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
            == "--snapshot-of needs main, health, stats, review, palette, playlist, tags, settings, playback, appearance, toolbar, folders, shortcuts, statusBar, headerStatus, toolbarSheet, downloads"
    )
    #expect(
        argumentProblem(["--snapshot", "/s.png", "--snapshot-of", "--measure-window"])
            == "--snapshot-of needs main, health, stats, review, palette, playlist, tags, settings, playback, appearance, toolbar, folders, shortcuts, statusBar, headerStatus, toolbarSheet, downloads"
    )
    #expect(
        argumentProblem(["--snapshot", "/s.png", "--snapshot-of", "queue"])
            == "--snapshot-of needs one of main, health, stats, review, palette, playlist, tags, settings, playback, appearance, toolbar, folders, shortcuts, statusBar, headerStatus, toolbarSheet, downloads, not queue"
    )
    #expect(
        argumentProblem(["--snapshot-of", "palette"]) == "--snapshot-of only goes with --snapshot")
}

@Test func captureRenderersNeedsAFolderAndIsAModeOfItsOwn() {
    #expect(argumentProblem(["--capture-renderers", "/c"]) == nil)
    #expect(
        argumentProblem(["--capture-renderers"]) == "--capture-renderers needs a folder to write to"
    )
    #expect(
        argumentProblem(["--capture-renderers", "/c", "--snapshot", "/s.png"])
            == "--snapshot is for the window, so it can't go with --capture-renderers")
}

@Test func aScrollMeasurementNeedsAKnownCaseAndADelayOnlyWithIt() {
    #expect(argumentProblem(["--measure-scroll", "trackpad", "--art-delay-ms", "43"]) == nil)
    #expect(
        argumentProblem(["--measure-scroll"])
            == "--measure-scroll needs trackpad, scan, pages, resize")
    #expect(
        argumentProblem(["--measure-scroll", "drag"])
            == "--measure-scroll needs one of trackpad, scan, pages, resize, not drag")
    #expect(
        argumentProblem(["--measure-scroll", "scan", "--measure-window"])
            == "--measure-scroll can't go with --measure-window")
    #expect(argumentProblem(["--measure-launch"]) == nil)
    #expect(
        argumentProblem(["--measure-launch", "--measure-scroll", "pages"])
            == "--measure-scroll can't go with --measure-launch")
    #expect(
        argumentProblem(["--measure-launch", "--scan", "/m"])
            == "--measure-launch is for the window, so it can't go with --scan")
    #expect(
        argumentProblem(["--art-delay-ms", "43"])
            == "--art-delay-ms only goes with --measure-scroll")
    #expect(
        argumentProblem(["--measure-scroll", "scan", "--art-delay-ms"])
            == "--art-delay-ms needs milliseconds")
    #expect(
        argumentProblem(["--measure-scroll", "scan", "--art-delay-ms", "-1"])
            == "--art-delay-ms needs a number of milliseconds, not -1")
    #expect(
        argumentProblem(["--measure-scroll", "scan", "--scan", "/m"])
            == "--measure-scroll is for the window, so it can't go with --scan")
}

@Test func theRelaunchsRescanFlagIsTheWindows() {
    #expect(argumentProblem(["--rescan-confirmed", "on"]) == nil)
    #expect(argumentProblem(["--rescan-confirmed", "off"]) == nil)
    #expect(argumentProblem(["--rescan-confirmed"]) == "--rescan-confirmed needs off, on")
    #expect(
        argumentProblem(["--rescan-confirmed", "yes"])
            == "--rescan-confirmed needs one of off, on, not yes")
    #expect(
        argumentProblem(["--scan", "/m", "--rescan-confirmed", "on"])
            == "--rescan-confirmed is for the window, so it can't go with --scan")
    #expect(rescanConfirmed("on") == true && rescanConfirmed("off") == false)
    #expect(rescanConfirmedArguments(false) == ["--rescan-confirmed", "off"])
}

@Test func theRelaunchDropsTheRescanFlagAndItsValue() {
    #expect(
        relaunchArguments(
            from: ["--home", "/h", "--rescan-confirmed", "on", "--report-launch"],
            adding: rescanConfirmedArguments(false))
            == ["--home", "/h", "--report-launch", "--rescan-confirmed", "off"])
    #expect(relaunchArguments(from: ["--rescan-confirmed"], adding: []) == [])
    #expect(relaunchArguments(from: ["-NSFoo", "YES"], adding: []) == ["-NSFoo", "YES"])
}

@Test func theRelaunchGivesUpOnAProcessThatKeepsRunning() throws {
    let running = Process()
    running.executableURL = URL(fileURLWithPath: "/bin/sleep", isDirectory: false)
    running.arguments = ["10"]
    try running.run()
    defer { running.terminate() }
    let relaunch = Process()
    relaunch.executableURL = URL(fileURLWithPath: "/bin/sh", isDirectory: false)
    // An app path that isn't one, so a relaunch that didn't give up opens nothing.
    relaunch.arguments = [
        "-c", relaunchScript(waitingFor: running.processIdentifier, upTo: 0.4), "relaunch",
        "/nonexistent/Music Player.app",
    ]
    try relaunch.run()
    relaunch.waitUntilExit()
    #expect(relaunch.terminationStatus == relaunchGaveUpStatus)
    #expect(running.isRunning)
}
