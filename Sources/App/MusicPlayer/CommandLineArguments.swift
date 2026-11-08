import DisplayText
import Foundation
import LibraryBrowser
import Metadata

/// Every flag the app takes; main.swift lists what each does.
enum Flag: String {
    case listDevices = "--list-devices"
    case captureRenderers = "--capture-renderers"
    case play = "--play"
    case device = "--device"
    case scan = "--scan"
    case db = "--db"
    case readers = "--readers"
    case scanIOHints = "--scan-io-hints"
    case settings = "--settings"
    case home = "--home"
    case measureWindow = "--measure-window"
    case measureLaunch = "--measure-launch"
    case measureScroll = "--measure-scroll"
    case artDelayMs = "--art-delay-ms"
    case reportLaunch = "--report-launch"
    case snapshot = "--snapshot"
    case snapshotOf = "--snapshot-of"
    case rescanConfirmed = "--rescan-confirmed"
}

/// The value after `flag`, or nil when the flag is absent, last, or followed by another flag.
func value(after flag: Flag, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag.rawValue), index + 1 < arguments.count,
        !arguments[index + 1].hasPrefix("--")
    else { return nil }
    return arguments[index + 1]
}

/// Writes `error` to standard error as the command line shows a failure.
func printError(_ error: Any) {
    FileHandle.standardError.write(Data("error: \(terminalSafe("\(error)"))\n".utf8))
}

/// Why `text` isn't one of the values `flag` takes, `choices`.
func choiceProblem(_ flag: Flag, _ choices: String, _ text: String) -> String {
    "\(flag.rawValue) needs one of \(choices), not \(text)"
}

/// What `--scan-io-hints` accepts, for its error messages.
let ioHintsChoices = ReadHints.allCases.map(\.rawValue).joined(separator: ", ")

/// What `--measure-scroll` accepts, for its error messages.
private let scrollChoices = ScrollCase.allCases.map(\.rawValue).joined(separator: ", ")

/// What `--snapshot-of` accepts, for its error messages.
private let snapshotChoices = SnapshotTarget.allCases.map(\.rawValue).joined(separator: ", ")

/// Each flag that takes a value, and what the value is.
private let valueFlags: [(Flag, String)] = [
    (.play, "a file or folder"), (.device, "part of a device name"), (.scan, "a folder"),
    (.db, "a database file"), (.readers, "a number of files to read at once"),
    (.scanIOHints, ioHintsChoices), (.settings, "a config file"), (.home, "a folder"),
    (.snapshot, "a PNG file to write"), (.snapshotOf, snapshotChoices),
    (.captureRenderers, "a folder to write to"), (.measureScroll, scrollChoices),
    (.artDelayMs, "milliseconds"),
]
/// The command-line modes, which run and exit without the window.
private let modeFlags: [Flag] = [.listDevices, .scan, .play, .captureRenderers]
/// Flags only the window uses.
private let windowFlags: [Flag] = [
    .measureWindow, .measureLaunch, .measureScroll, .artDelayMs, .reportLaunch, .snapshot,
    .snapshotOf, .rescanConfirmed,
]
private let scanOnlyFlags: [Flag] = [.db, .readers, .scanIOHints]

/// Why `arguments` (without the executable) can't run, or nil when they can. A mistake here would
/// otherwise fall through to opening the window, or quietly do nothing.
func argumentProblem(_ arguments: [String]) -> String? {
    let given = { (flag: Flag) in arguments.contains(flag.rawValue) }
    let known = Set((valueFlags.map(\.0) + modeFlags + windowFlags).map(\.rawValue))
    if let unknown = arguments.first(where: { $0.hasPrefix("--") && !known.contains($0) }) {
        return "\(unknown) isn't an option"
    }
    for (flag, what) in valueFlags where given(flag) && value(after: flag, in: arguments) == nil {
        return "\(flag.rawValue) needs \(what)"
    }
    if let flag = scanOnlyFlags.first(where: given), !given(.scan) {
        return "\(flag.rawValue) only goes with \(Flag.scan.rawValue)"
    }
    if given(.snapshotOf), !given(.snapshot) {
        return "\(Flag.snapshotOf.rawValue) only goes with \(Flag.snapshot.rawValue)"
    }
    if let text = value(after: .snapshotOf, in: arguments), SnapshotTarget(rawValue: text) == nil {
        return choiceProblem(.snapshotOf, snapshotChoices, text)
    }
    if let text = value(after: .measureScroll, in: arguments), ScrollCase(rawValue: text) == nil {
        return choiceProblem(.measureScroll, scrollChoices, text)
    }
    let measurements = [Flag.measureWindow, .measureLaunch, .measureScroll].filter(given)
    if measurements.count > 1 {
        return "\(measurements[1].rawValue) can't go with \(measurements[0].rawValue)"
    }
    if given(.artDelayMs), !given(.measureScroll) {
        return "\(Flag.artDelayMs.rawValue) only goes with \(Flag.measureScroll.rawValue)"
    }
    if let text = value(after: .artDelayMs, in: arguments), artDelaySeconds(text) == nil {
        return "\(Flag.artDelayMs.rawValue) needs a number of milliseconds, not \(text)"
    }
    if let window = windowFlags.first(where: given), let mode = modeFlags.first(where: given) {
        return "\(window.rawValue) is for the window, so it can't go with \(mode.rawValue)"
    }
    return nil
}

/// `--art-delay-ms`'s text as seconds, or nil when it isn't a number of milliseconds.
func artDelaySeconds(_ text: String) -> Double? {
    guard let milliseconds = Double(text), milliseconds >= 0, milliseconds.isFinite else {
        return nil
    }
    return milliseconds / 1000
}
