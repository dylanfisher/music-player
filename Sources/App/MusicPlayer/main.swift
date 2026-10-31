import AppKit
import HALOutput
import Library
import Metadata
import Settings

// Command-line modes, run from Terminal on the Mac the DAC is attached to:
//   MusicPlayer --list-devices
//   MusicPlayer --play <file> [--device <part of name>]
//   MusicPlayer --export-settings <file>
//   MusicPlayer --import-settings <file>
//   MusicPlayer --scan <folder> [--db <file>] [--readers <n>] [--scan-io-hints none|rdahead|all]
let arguments = CommandLine.arguments

func value(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
        return nil
    }
    return arguments[index + 1]
}

/// 312.4 -> "5:12".
func clock(_ seconds: Double) -> String {
    let whole = Int(seconds)
    return "\(whole / 60):" + String(format: "%02d", whole % 60)
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

let ioHintsChoices = ReadHints.allCases.map(\.rawValue).joined(separator: ", ")

// A flag with nothing after it would otherwise fall through to launching the GUI.
for (flag, what) in [
    ("--export-settings", "a file"), ("--import-settings", "a file"), ("--play", "a file"),
    ("--device", "part of a device name"), ("--scan", "a folder"), ("--db", "a database file"),
    ("--readers", "a number of files to read at once"),
    ("--scan-io-hints", ioHintsChoices),
] where arguments.contains(flag) && value(after: flag) == nil {
    FileHandle.standardError.write(Data("error: \(flag) needs \(what)\n".utf8))
    exit(1)
}

for flag in ["--db", "--readers", "--scan-io-hints"]
where arguments.contains(flag) && !arguments.contains("--scan") {
    FileHandle.standardError.write(Data("error: \(flag) only goes with --scan\n".utf8))
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

if arguments.contains("--list-devices") {
    runAndExit { print(deviceReport(try AudioDevice.outputDevices())) }
}
if let path = value(after: "--export-settings") {
    runAndExit {
        let settings = try SettingsStore(AppSettings(), fileURL: try defaultSettingsFileURL())
        try settings.export(to: URL(fileURLWithPath: path))
        print("exported every setting to \(path)")
    }
}
if let path = value(after: "--import-settings") {
    runAndExit {
        let settings = try SettingsStore(AppSettings(), fileURL: try defaultSettingsFileURL())
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
/// Set from signal handlers on another thread, read by the playback loop.
final class StopRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    /// Returns how many times a stop has been requested, including this one.
    func request() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
    var isRequested: Bool { lock.withLock { count > 0 } }
}

/// The first Ctrl-C (or the terminal closing) stops playback so the device gets restored. A second
/// one quits at once, in case restoring hangs.
func stopOnSignals(_ stop: StopRequest) -> [DispatchSourceSignal] {
    [SIGINT, SIGTERM, SIGHUP].map { number in
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
        source.setEventHandler {
            if stop.request() > 1 { exit(128 + number) }
        }
        source.resume()
        return source
    }
}

if let path = value(after: "--play") {
    let stop = StopRequest()
    // Signal sources stop firing once released, so hold them for the whole run.
    let signalSources = stopOnSignals(stop)
    runAndExit {
        try withExtendedLifetime(signalSources) {
            try playFile(
                at: URL(fileURLWithPath: path), deviceName: value(after: "--device"),
                // Progress rewrites one line in place, so log lines clear it first.
                log: {
                    print(eraseLine + $0)
                    fflush(stdout)
                },
                progress: { played, duration in
                    print("\r  \(clock(played)) / \(clock(duration))", terminator: "")
                    fflush(stdout)
                },
                shouldStop: { stop.isRequested })
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
