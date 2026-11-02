import DisplayText
import Foundation
import LocalNetwork
import Receiver
import Settings

enum CaptureCommandError: Error, CustomStringConvertible {
    case nothingCaptured

    var description: String {
        switch self {
        case .nothingCaptured: "nothing was captured"
        }
    }
}

/// `MusicPlayer --capture-renderers <folder>`: searches the local network for MediaRenderers
/// and the Denon receiver and writes what they send, unparsed, to `folder` (ADR 0039).
@MainActor
func captureRenderersCommand(folder: String) throws {
    let configured = try readConfig(try appPaths())[\.receiverAddress]?.address
    let url = URL(fileURLWithPath: folder, isDirectory: true)
    print("searching the network and listening to the receiver, about 20 s")
    fflush(stdout)
    let done = DispatchSemaphore(value: 0)
    let reported = ReportBox()
    // Detached, because the caller runs on the main actor, which the semaphore blocks.
    Task.detached {
        reported.report = await NetworkCapture.run(
            folder: url,
            transport: UDPSearchTransport(
                destination: SSDPSearch.multicastGroup, port: SSDPSearch.port),
            interfaces: { try currentInterfaces() }, configured: configured)
        done.signal()
    }
    done.wait()
    let report = reported.report
    print(terminalSafe("wrote \(report.written.count) files to \(url.path)"))
    for name in report.written { print(terminalSafe("  \(name)")) }
    if !report.failures.isEmpty { print("failed:") }
    for failure in report.failures { print(terminalSafe("  \(failure)")) }
    guard report.capturedAnything else { throw CaptureCommandError.nothingCaptured }
}

private final class ReportBox: @unchecked Sendable {
    var report = NetworkCapture.Report()
}
