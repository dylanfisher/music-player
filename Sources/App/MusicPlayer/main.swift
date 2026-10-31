import AppKit
import HALOutput
import Library
import Metadata
import Settings

// Command-line modes, run from Terminal on the Mac the DAC is attached to:
//   MusicPlayer --list-devices
//   MusicPlayer --play <file or folder>... [--device <part of name>]
//   MusicPlayer --export-settings <file>
//   MusicPlayer --import-settings <file>
//   MusicPlayer --scan <folder> [--db <file>] [--readers <n>] [--scan-io-hints none|rdahead|all]
// and the window:
//   MusicPlayer [--settings <file>] [--measure-window] [--snapshot <png file>]
// --settings reads another settings file, and the library beside it, in every mode.
// --measure-window prints the launch time and memory as JSON and quits, for Bench.
// --snapshot draws the window into a PNG a few seconds after its first rows, to check the layout.
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

/// The settings file from `--settings`, or the default one.
func settingsFileURL() throws -> URL {
    try value(after: "--settings").map(URL.init(fileURLWithPath:)) ?? defaultSettingsFileURL()
}

if arguments.contains("--list-devices") {
    runAndExit { print(deviceReport(try AudioDevice.outputDevices())) }
}
if let path = value(after: "--export-settings") {
    runAndExit {
        let settings = try SettingsStore(AppSettings(), fileURL: try settingsFileURL())
        try settings.export(to: URL(fileURLWithPath: path))
        print("exported every setting to \(path)")
    }
}
if let path = value(after: "--import-settings") {
    runAndExit {
        let settings = try SettingsStore(AppSettings(), fileURL: try settingsFileURL())
        let count = try settings.importSettings(from: URL(fileURLWithPath: path))
        print("imported \(count) settings into \(settings.fileURL.path)")
    }
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

let launchSettingsURL: URL
do {
    launchSettingsURL = try settingsFileURL()
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
let app = NSApplication.shared
let delegate = AppDelegate(
    settingsURL: launchSettingsURL, measuring: arguments.contains("--measure-window"),
    snapshotURL: value(after: "--snapshot").map(URL.init(fileURLWithPath:)))
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
