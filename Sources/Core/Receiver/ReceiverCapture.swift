import Foundation
import LocalNetwork
import UPnP

/// The command-line capture of what the owner's receiver sends, saved raw for 9b to start from
/// (ADR 0039): the renderers' documents, then the receiver's status lines. It sends discovery's
/// requests and the five status queries, which read state and change nothing.
public enum NetworkCapture {
    public struct Report: Sendable {
        /// The files written.
        public var written: [String] = []
        /// What went wrong, one line each; a failure doesn't stop the rest.
        public var failures: [String] = []
        /// Whether any file was written.
        public var capturedAnything: Bool { !written.isEmpty }

        public init() {}
    }

    /// How long the status lines are recorded.
    static let statusSeconds = 10.0
    static let statusFile = "status-lines.txt"

    /// Captures into `folder`. The receiver is the Denon the search finds, or else `configured`
    /// (`receiver.address`) while it's another device on a local subnet.
    public static func run(
        folder: URL, transport: some SSDPTransport, interfaces: () throws -> [NetworkInterface],
        configured: LocalNetwork.IPAddress?
    ) async -> Report {
        await run(
            folder: folder, transport: transport, interfaces: interfaces, configured: configured,
            port: ReceiverConnection.port, searchSeconds: RendererCapture.searchSeconds,
            statusSeconds: statusSeconds)
    }

    static func run(
        folder: URL, transport: some SSDPTransport, interfaces: () throws -> [NetworkInterface],
        configured: LocalNetwork.IPAddress?, port: UInt16, searchSeconds: Double,
        statusSeconds: Double
    ) async -> Report {
        var report = Report()
        let up: [NetworkInterface]
        do {
            up = try interfaces()
        } catch {
            report.failures.append("the network interfaces couldn't be listed: \(error)")
            return report
        }
        let subnets = LocalSubnets(up)
        let renderers = await RendererCapture.run(
            transport: transport, subnets: subnets, seconds: searchSeconds)
        var files = renderers.files
        report.failures += renderers.failures
        switch receiverAddress(among: renderers.renderers, configured: configured, subnets: subnets)
        {
        case .success(let address):
            let status = await recordStatus(address: address, port: port, seconds: statusSeconds)
            if let file = status.file { files.append(file) }
            report.failures += status.failures
        case .failure(let why):
            report.failures.append("\(statusFile): \(why)")
        }
        do {
            let writing = try CaptureFile.write(files, to: folder)
            report.written = writing.written
            report.failures += writing.failures
        } catch {
            report.failures.append("\(folder.path) couldn't be made: \(error)")
        }
        return report
    }

    /// The receiver's address by the rule receiver control uses: the Denon the search found,
    /// or else the configured address if it's another device on a local subnet.
    private static func receiverAddress(
        among renderers: [Renderer], configured: LocalNetwork.IPAddress?, subnets: LocalSubnets
    ) -> Result<LocalNetwork.IPAddress, CaptureProblem> {
        switch ReceiverControl.receiver(among: renderers, configured: configured) {
        case .found(let renderer): return .success(renderer.address)
        case .several(let why): return .failure(CaptureProblem(why))
        case .none:
            guard let configured else {
                return .failure(
                    CaptureProblem(
                        "no Denon receiver answered, and receiver.address isn't set"))
            }
            guard subnets.interface(forHost: configured) != nil else {
                return .failure(
                    CaptureProblem(
                        "no Denon receiver answered, and the receiver address \(configured) isn't"
                            + " another device's address on a local subnet"))
            }
            return .success(configured)
        }
    }

    /// Connects to the receiver's control port, asks for its state and records every line it
    /// sends for `seconds`, each with the seconds since the connection opened. The file is
    /// made only when a line came.
    static func recordStatus(address: LocalNetwork.IPAddress, port: UInt16, seconds: Double) async
        -> (file: CaptureFile?, failures: [String])
    {
        let (updates, continuation) = AsyncStream.makeStream(of: ReceiverConnection.Update.self)
        let connection = ReceiverConnection(address: address, port: port) { update in
            continuation.yield(update)
            if case .ended = update { continuation.finish() }
        }
        connection.start()
        var opened: Double?
        var lines: [String] = []
        var failures: [String] = []
        var received = 0
        let timer = Task {
            // Cancelled when the connection ends first.
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            continuation.finish()
        }
        func stamp(_ note: String) -> String {
            String(format: "%.3f\t", ProcessInfo.processInfo.systemUptime - (opened ?? 0)) + note
        }
        for await update in updates {
            switch update {
            case .connected:
                opened = ProcessInfo.processInfo.systemUptime
                lines.append(stamp("# connected to \(address)"))
                for query in statusQueries { connection.send(query) }
            case .line(_, let text):
                received += 1
                lines.append(stamp(text))
            case .ended(let reason):
                lines.append(stamp("# ended: \(reason)"))
                failures.append("\(statusFile): \(reason)")
            }
        }
        timer.cancel()
        connection.stop()
        guard received > 0 else {
            if failures.isEmpty { failures.append("\(statusFile): no line came in \(seconds) s") }
            return (nil, failures)
        }
        return (
            CaptureFile(
                name: statusFile, bytes: Array((lines.joined(separator: "\n") + "\n").utf8)),
            failures
        )
    }
}

private struct CaptureProblem: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) { self.description = description }
}
