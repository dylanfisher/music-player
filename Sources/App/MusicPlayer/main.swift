import AppKit
import HALOutput
import Library
import LibraryBrowser
import Metadata
import Settings

// Command-line modes, run from Terminal on the Mac the DAC is attached to:
//   MusicPlayer --list-devices
//   MusicPlayer --capture-renderers <folder>
//   MusicPlayer --play <file or folder>... [--device <part of name>]
//   MusicPlayer --scan <folder> [--db <file>] [--readers <n>] [--scan-io-hints none|rdahead|all]
// and the window:
//   MusicPlayer [--measure-window | --measure-launch
//     | --measure-scroll trackpad|scan|pages|resize [--art-delay-ms <ms>]]
//     [--report-launch] [--snapshot <png file> [--snapshot-of <window>]] [--rescan-confirmed]
// and in every mode [--home <folder>] [--settings <file>]:
// --home keeps the config file, library, state file and device record in one folder instead of
// ~/.config/music-player and Application Support, for tests and runs on the build Mac.
// --settings reads another config file.
// --list-devices lists the output devices, then the UPnP renderers a search of the local network
// finds, with the UDN output.renderer takes.
// --capture-renderers writes what the UPnP renderers and the Denon receiver on the network send
// (SSDP replies, descriptions, status lines) to the folder, for phase 9b to start from.
// --measure-window prints the launch time and memory as JSON and quits, for Bench.
// --measure-launch prints only the time from the process's start to the first rows, and the
// memory then, and quits: for a cold launch after `sudo purge`, with the owner's own library.
// --measure-scroll times the track table's frames as JSON and quits, for Bench: trackpad flicks,
// the same while hearing a scan's progress, a screenful at a time once each screen's art is in,
// or the window and the art column resized a frame at a time. --art-delay-ms adds a NAS's
// latency to each art read.
// --report-launch prints "launched" once every watched folder's scan at launch has ended, or the
// watcher has left it to the index, for Bench to know the app is idle.
// --snapshot draws the window into a PNG a few seconds after its first rows, to check the layout.
// --snapshot-of draws Library Health, Listening Stats, Year in Review, the palette, the smart
// playlist editor, the tag editor, or the Settings window's General or Shortcuts pane, instead.
// --rescan-confirmed rebuilds the index without asking, which the relaunch after a Rescan Now
// passes, as the question was asked already (ADR 0143).
let arguments = CommandLine.arguments

func value(after flag: Flag) -> String? { value(after: flag, in: arguments) }

func given(_ flag: Flag) -> Bool { arguments.contains(flag.rawValue) }

/// Everything after `flag` up to the next flag.
func values(after flag: Flag) -> [String] {
    guard let index = arguments.firstIndex(of: flag.rawValue) else { return [] }
    return Array(arguments[(index + 1)...].prefix { !$0.hasPrefix("--") })
}

func runAndExit(_ command: () throws -> Void) -> Never {
    do {
        try command()
        exit(0)
    } catch {
        printError(error)
        exit(1)
    }
}

if let problem = argumentProblem(Array(arguments.dropFirst())) {
    printError(problem)
    exit(1)
}

let readers = value(after: .readers).map { text in
    let range = AppSettings.networkScanReadersRange
    guard let count = Int(text), range.contains(count) else {
        printError(
            "\(Flag.readers.rawValue) needs a whole number from \(range.lowerBound) to"
                + " \(range.upperBound), not \(text)")
        exit(1)
    }
    return count
}

let ioHints = value(after: .scanIOHints).map { text in
    guard let hints = ReadHints(rawValue: text) else {
        printError(choiceProblem(.scanIOHints, ioHintsChoices, text))
        exit(1)
    }
    return hints
}

/// The app's files: in `--home`'s folder or the standard places, with `--settings`'s config file.
func appPaths() throws -> AppPaths {
    var paths =
        try value(after: .home).map { AppPaths(home: URL(fileURLWithPath: $0, isDirectory: true)) }
        ?? AppPaths.standard()
    if let file = value(after: .settings) {
        paths.configFile = URL(fileURLWithPath: file, isDirectory: false)
    }
    return paths
}

if given(.listDevices) {
    runAndExit {
        print(deviceReport(try AudioDevice.outputDevices()))
        print(rendererListing())
    }
}
if let folder = value(after: .captureRenderers) {
    runAndExit { try captureRenderersCommand(folder: folder) }
}
if let folder = value(after: .scan) {
    runAndExit {
        try scanCommand(
            folder: folder, databasePath: value(after: .db), readers: readers,
            hints: ioHints ?? SystemFileAccess().hints)
    }
}
if given(.play) {
    runAndExit {
        try playCommand(paths: values(after: .play), deviceName: value(after: .device))
    }
}

let snapshotTarget =
    value(after: .snapshotOf).map { text in
        guard let target = SnapshotTarget(rawValue: text) else {
            preconditionFailure("argumentProblem lets only a snapshot target through, not \(text)")
        }
        return target
    } ?? .main

let launchPaths: AppPaths
do {
    launchPaths = try appPaths()
} catch {
    printError(error)
    exit(1)
}
let measurement: MeasurementKind? =
    if given(.measureWindow) {
        .window
    } else if given(.measureLaunch) {
        .launch
    } else if let text = value(after: .measureScroll), let scrollCase = ScrollCase(rawValue: text) {
        .scroll(
            scrollCase,
            artDelaySeconds: value(after: .artDelayMs).flatMap(artDelaySeconds) ?? 0)
    } else {
        nil
    }

let app = NSApplication.shared
let delegate = AppDelegate(
    paths: launchPaths, measuring: measurement, reportingLaunch: given(.reportLaunch),
    snapshotURL: value(after: .snapshot).map { URL(fileURLWithPath: $0, isDirectory: false) },
    snapshotOf: snapshotTarget, rescanConfirmed: given(.rescanConfirmed))
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
