import Metadata

/// The value after `flag`, or nil when the flag is absent, last, or followed by another flag.
func value(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count,
        !arguments[index + 1].hasPrefix("--")
    else { return nil }
    return arguments[index + 1]
}

/// What `--scan-io-hints` accepts, for its error messages.
let ioHintsChoices = ReadHints.allCases.map(\.rawValue).joined(separator: ", ")

/// What `--snapshot-of` accepts, for its error messages.
private let snapshotChoices = SnapshotTarget.allCases.map(\.rawValue).joined(separator: ", ")

/// Each flag that takes a value, and what the value is.
private let valueFlags = [
    ("--play", "a file or folder"), ("--device", "part of a device name"),
    ("--scan", "a folder"), ("--db", "a database file"),
    ("--readers", "a number of files to read at once"), ("--scan-io-hints", ioHintsChoices),
    ("--settings", "a config file"), ("--home", "a folder"), ("--snapshot", "a PNG file to write"),
    ("--snapshot-of", snapshotChoices),
]
/// The command-line modes, which run and exit without the window.
private let modeFlags = [
    "--list-devices", "--scan", "--play",
]
/// Flags only the window uses.
private let windowFlags = ["--measure-window", "--snapshot", "--snapshot-of"]
private let scanOnlyFlags = ["--db", "--readers", "--scan-io-hints"]

/// Why `arguments` (without the executable) can't run, or nil when they can. A mistake here would
/// otherwise fall through to opening the window, or quietly do nothing.
func argumentProblem(_ arguments: [String]) -> String? {
    let known = Set(valueFlags.map(\.0) + modeFlags + windowFlags)
    if let unknown = arguments.first(where: { $0.hasPrefix("--") && !known.contains($0) }) {
        return "\(unknown) isn't an option"
    }
    for (flag, what) in valueFlags
    where arguments.contains(flag) && value(after: flag, in: arguments) == nil {
        return "\(flag) needs \(what)"
    }
    if let flag = scanOnlyFlags.first(where: arguments.contains), !arguments.contains("--scan") {
        return "\(flag) only goes with --scan"
    }
    if arguments.contains("--snapshot-of"), !arguments.contains("--snapshot") {
        return "--snapshot-of only goes with --snapshot"
    }
    if let text = value(after: "--snapshot-of", in: arguments),
        SnapshotTarget(rawValue: text) == nil
    {
        return "--snapshot-of needs one of \(snapshotChoices), not \(text)"
    }
    if let window = windowFlags.first(where: arguments.contains),
        let mode = modeFlags.first(where: arguments.contains)
    {
        return "\(window) is for the window, so it can't go with \(mode)"
    }
    return nil
}
