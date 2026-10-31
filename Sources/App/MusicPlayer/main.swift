import AppKit
import HALOutput
import Library
import Metadata
import Settings

// Command-line modes, run from Terminal on the Mac the DAC is attached to:
//   MusicPlayer --list-devices
//   MusicPlayer --play <file or folder>... [--device <part of name>]
//   MusicPlayer --scan <folder> [--db <file>] [--readers <n>] [--scan-io-hints none|rdahead|all]
// and the window:
//   MusicPlayer [--measure-window] [--snapshot <png file> [--snapshot-of <window>]]
// and in every mode [--home <folder>] [--settings <file>]:
// --home keeps the config file, library, state file and device record in one folder instead of
// ~/.config/music-player and Application Support, for tests and runs on the build Mac.
// --settings reads another config file.
// --measure-window prints the launch time and memory as JSON and quits, for Bench.
// --snapshot draws the window into a PNG a few seconds after its first rows, to check the layout.
// --snapshot-of draws the palette, the smart playlist editor, or the Settings window's General or
// Shortcuts pane, instead.
let arguments = CommandLine.arguments

func value(after flag: String) -> String? { value(after: flag, in: arguments) }

/// Everything after `flag` up to the next flag.
func values(after flag: String) -> [String] {
    guard let index = arguments.firstIndex(of: flag) else { return [] }
    return Array(arguments[(index + 1)...].prefix { !$0.hasPrefix("--") })
}

func runAndExit(_ command: () throws -> Void) -> Never {
    do {
        try command()
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exit(1)
    }
}

if let problem = argumentProblem(Array(arguments.dropFirst())) {
    FileHandle.standardError.write(Data("error: \(problem)\n".utf8))
    exit(1)
}

let readers = value(after: "--readers").map { text in
    let range = AppSettings.networkScanReadersRange
    guard let count = Int(text), range.contains(count) else {
        FileHandle.standardError.write(
            Data(
                "error: --readers needs a whole number from \(range.lowerBound) to \(range.upperBound), not \(text)\n"
                    .utf8))
        exit(1)
    }
    return count
}

let ioHints = value(after: "--scan-io-hints").map { text in
    guard let hints = ReadHints(rawValue: text) else {
        FileHandle.standardError.write(
            Data("error: --scan-io-hints needs one of \(ioHintsChoices), not \(text)\n".utf8))
        exit(1)
    }
    return hints
}

/// The app's files: in `--home`'s folder or the standard places, with `--settings`'s config file.
func appPaths() throws -> AppPaths {
    var paths =
        try value(after: "--home").map { AppPaths(home: URL(fileURLWithPath: $0)) }
        ?? AppPaths.standard()
    if let file = value(after: "--settings") { paths.configFile = URL(fileURLWithPath: file) }
    return paths
}

if arguments.contains("--list-devices") {
    runAndExit { print(deviceReport(try AudioDevice.outputDevices())) }
}
if let folder = value(after: "--scan") {
    runAndExit {
        try scanCommand(
            folder: folder, databasePath: value(after: "--db"), readers: readers,
            hints: ioHints ?? SystemFileAccess().hints)
    }
}
if arguments.contains("--play") {
    runAndExit {
        try playCommand(paths: values(after: "--play"), deviceName: value(after: "--device"))
    }
}

let snapshotTarget =
    value(after: "--snapshot-of").map { text in
        guard let target = SnapshotTarget(rawValue: text) else {
            preconditionFailure("argumentProblem lets only a snapshot target through, not \(text)")
        }
        return target
    } ?? .main

let launchPaths: AppPaths
do {
    launchPaths = try appPaths()
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
let app = NSApplication.shared
let delegate = AppDelegate(
    paths: launchPaths, measuring: arguments.contains("--measure-window"),
    snapshotURL: value(after: "--snapshot").map(URL.init(fileURLWithPath:)),
    snapshotOf: snapshotTarget)
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
