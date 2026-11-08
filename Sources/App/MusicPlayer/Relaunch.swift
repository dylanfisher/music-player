import AppKit
import Foundation

extension AppDelegate {
    /// Quits, and opens the app again with the same arguments once this process has ended, so
    /// the next launch finds no connection open on the index. Outside an app bundle, as from
    /// `swift run`, it only quits, and the next launch does what the relaunch was for.
    /// `failure` is what the alert says when the app can't be opened again.
    func relaunch(failing failure: String) {
        let app = Bundle.main.bundleURL
        if app.pathExtension == "app" {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh", isDirectory: false)
            process.arguments =
                [
                    "-c",
                    "while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null;"
                        + " do /bin/sleep 0.2; done; app=$1; shift; exec /usr/bin/open -n \"$app\""
                        + " --args \"$@\"",
                    "relaunch", app.path,
                ] + CommandLine.arguments.dropFirst()
            do {
                try process.run()
            } catch {
                fail(failure, error)
            }
        }
        NSApp.terminate(nil)
    }
}
