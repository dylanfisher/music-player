import DisplayText
import Foundation
import Metadata

/// Every flag the app takes; main.swift lists what each does.
enum Flag: String {
    case listDevices = "--list-devices"
    case play = "--play"
    case device = "--device"
    case scan = "--scan"
    case db = "--db"
    case readers = "--readers"
    case scanIOHints = "--scan-io-hints"
    case settings = "--settings"
    case home = "--home"
    case measureWindow = "--measure-window"
    case snapshot = "--snapshot"
    case snapshotOf = "--snapshot-of"
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

/// What `--snapshot-of` accepts, for its error messages.
private let snapshotChoices = SnapshotTarget.allCases.map(\.rawValue).joined(separator: ", ")

/// Each flag that takes a value, and what the value is.
private let valueFlags: [(Flag, String)] = [
    (.play, "a file or folder"), (.device, "part of a device name"), (.scan, "a folder"),
    (.db, "a database file"), (.readers, "a number of files to read at once"),
    (.scanIOHints, ioHintsChoices), (.settings, "a config file"), (.home, "a folder"),
    (.snapshot, "a PNG file to write"), (.snapshotOf, snapshotChoices),
]
/// The command-line modes, which run and exit without the window.
private let modeFlags: [Flag] = [.listDevices, .scan, .play]
/// Flags only the window uses.
private let windowFlags: [Flag] = [.measureWindow, .snapshot, .snapshotOf]
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
    if let window = windowFlags.first(where: given), let mode = modeFlags.first(where: given) {
        return "\(window.rawValue) is for the window, so it can't go with \(mode.rawValue)"
    }
    return nil
}
