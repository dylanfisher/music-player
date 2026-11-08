import AppKit
import Foundation

extension AppDelegate {
    /// Quits, and opens the app again with the same arguments once this process has ended, so
    /// the next launch finds no connection open on the index. A quit that is cancelled, or
    /// that takes longer than `relaunchWaitSeconds`, opens nothing. Outside an app bundle, as from
    /// `swift run`, it only quits, and the next launch does what the relaunch was for.
    /// `adding` goes to the next launch's arguments, and to no later one's. `failure` is what
    /// the alert says when the app can't be opened again.
    func relaunch(adding extra: [String] = [], failing failure: String) {
        let arguments = relaunchArguments(
            from: Array(CommandLine.arguments.dropFirst()), adding: extra)
        let app = Bundle.main.bundleURL
        if app.pathExtension == "app" {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh", isDirectory: false)
            process.arguments =
                [
                    "-c",
                    relaunchScript(
                        waitingFor: ProcessInfo.processInfo.processIdentifier,
                        upTo: relaunchWaitSeconds),
                    "relaunch", app.path,
                ] + arguments
            do {
                try process.run()
            } catch {
                fail(failure, error)
            }
        }
        NSApp.terminate(nil)
    }
}

/// `arguments`, without the executable, as the relaunch passes them on: without
/// `--rescan-confirmed` and its value, which is for one launch, and with `extra`.
func relaunchArguments(from arguments: [String], adding extra: [String]) -> [String] {
    var kept: [String] = []
    var index = arguments.startIndex
    while index < arguments.endIndex {
        if arguments[index] == Flag.rescanConfirmed.rawValue {
            index += 1
            if index < arguments.endIndex, !arguments[index].hasPrefix("--") { index += 1 }
        } else {
            kept.append(arguments[index])
            index += 1
        }
    }
    return kept + extra
}

/// How long the relaunch waits for this process to end before it gives up, so a quit the user
/// cancelled doesn't open the app again at a later quit.
let relaunchWaitSeconds = 30.0

/// What the relaunch's exit status is when it gave up waiting.
let relaunchGaveUpStatus: Int32 = 3

/// The shell script that waits up to `seconds` for process `pid` to end, then opens the app
/// at `$1` with the rest of its arguments; it exits with `relaunchGaveUpStatus` if `pid` is
/// still running then.
func relaunchScript(waitingFor pid: Int32, upTo seconds: Double) -> String {
    let polls = Int((seconds / 0.2).rounded(.up))
    return "n=0; while /bin/kill -0 \(pid) 2>/dev/null; do n=$((n + 1));"
        + " [ \"$n\" -gt \(polls) ] && exit \(relaunchGaveUpStatus); /bin/sleep 0.2; done;"
        + " app=$1; shift; exec /usr/bin/open -n \"$app\" --args \"$@\""
}
