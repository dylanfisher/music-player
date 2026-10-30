import AppKit
import HALOutput
import Playback

// Command-line modes, run from Terminal on the Mac the DAC is attached to:
//   MusicPlayer --list-devices
//   MusicPlayer --play <file> [--device <part of name>]
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

if arguments.contains("--list-devices") {
    runAndExit { print(deviceReport(try AudioDevice.outputDevices())) }
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
                // Progress rewrites one line in place, so log lines clear it first ("\r" + erase line).
                log: {
                    print("\r\u{1B}[K\($0)")
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
