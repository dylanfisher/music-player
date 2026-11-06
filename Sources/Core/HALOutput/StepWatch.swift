import AudioToolbox
import Foundation
import Log

private let logger = moduleLogger()

/// Where the output reports what diagnoses playback: an underrun, and a call on the control
/// thread that hasn't returned (ADR 0121). The log by default; a test collects them.
struct OutputDiagnostics: Sendable {
    var stuckAfterSeconds = StepWatch.defaultThresholdSeconds
    /// A line and the file it's about, if any. The log keeps the path private (ADR 0118).
    var report: @Sendable (String, URL?) -> Void = { line, file in
        if let file {
            logger.error(
                "\(line, privacy: .public): \(file.path, privacy: .private(mask: .hash))")
        } else {
            logger.error("\(line, privacy: .public)")
        }
    }
}

/// Watches the control thread's calls that can block: a file call on a share that stopped
/// answering, or a HAL call the device doesn't return from. Neither can be timed out or cancelled
/// (ADR 0081), so the watch only names the call: one still running after `thresholdSeconds` is
/// reported, and reported again when it returns (ADR 0121). It wakes only while a call runs.
final class StepWatch: @unchecked Sendable {
    enum Step {
        case opening(URL)
        case reading(URL)
        case seeking(URL)
        case openingDevice(String)
        case configuringDevice(String)
        case startingDevice(String)
        case stoppingDevice(String)
        case closingDevice(String)

        var description: String {
            switch self {
            case .opening: "opening a track's file"
            case .reading: "reading a track's file"
            case .seeking: "seeking in a track's file"
            case .openingDevice(let name): "opening \(name)"
            case .configuringDevice(let name): "switching \(name) to the track's format"
            case .startingDevice(let name): "starting \(name)"
            case .stoppingDevice(let name): "stopping \(name)"
            case .closingDevice(let name): "closing \(name)"
            }
        }

        var file: URL? {
            switch self {
            case .opening(let url), .reading(let url), .seeking(let url): url
            case .openingDevice, .configuringDevice, .startingDevice, .stoppingDevice,
                .closingDevice:
                nil
            }
        }
    }

    /// Two seconds: longer than a NAS read or a device switch takes when nothing is wrong, and
    /// well before the ring buffer's margin for a stalled read runs out.
    static let defaultThresholdSeconds = 2.0

    let thresholdSeconds: Double
    private let report: @Sendable (String, URL?) -> Void
    private let lock = NSLock()
    /// The call running, numbered so a check that fires late can't report the next one.
    private var current: (step: Step, since: Double, id: UInt64)?
    private var lastID: UInt64 = 0
    /// The call reported as stuck, which its return reports again.
    private var reportedID: UInt64?
    /// Whether a check is scheduled. At most one is.
    private var armed = false

    init(_ diagnostics: OutputDiagnostics) {
        thresholdSeconds = diagnostics.stuckAfterSeconds
        report = diagnostics.report
    }

    func run<T>(_ step: Step, _ body: () throws -> T) rethrows -> T {
        let id = begin(step)
        defer { end(id) }
        return try body()
    }

    private func begin(_ step: Step) -> UInt64 {
        lock.withLock {
            lastID += 1
            current = (step, uptime(), lastID)
            if !armed {
                armed = true
                schedule(after: thresholdSeconds)
            }
            return lastID
        }
    }

    private func end(_ id: UInt64) {
        let returned = lock.withLock { () -> (Step, Double)? in
            defer { current = nil }
            guard reportedID == id, let current else { return nil }
            reportedID = nil
            return (current.step, uptime() - current.since)
        }
        if let (step, seconds) = returned {
            report(
                "playback carried on: \(step.description) returned after "
                    + String(format: "%.1f", seconds) + " s", step.file)
        }
    }

    private func schedule(after seconds: Double) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) { [self] in
            check()
        }
    }

    private func check() {
        let stuck = lock.withLock { () -> (Step, Double)? in
            guard let current, reportedID != current.id else {
                armed = false
                return nil
            }
            let seconds = uptime() - current.since
            guard seconds >= thresholdSeconds else {
                schedule(after: thresholdSeconds - seconds)
                return nil
            }
            reportedID = current.id
            armed = false
            return (current.step, seconds)
        }
        if let (step, seconds) = stuck {
            report(
                "playback is stuck: \(step.description) hasn't returned after "
                    + String(format: "%.1f", seconds) + " s", step.file)
        }
    }
}

/// A decoder whose calls the control thread's watch names: each can read the file.
final class WatchedDecoder: TrackDecoder {
    private let decoder: any TrackDecoder
    private let url: URL
    private let watch: StepWatch

    init(_ decoder: any TrackDecoder, url: URL, watch: StepWatch) {
        self.decoder = decoder
        self.url = url
        self.watch = watch
    }

    var lengthFrames: Int64 { decoder.lengthFrames }
    var nextFrame: Int64 { decoder.nextFrame }

    func setOutputFormat(_ format: AudioStreamBasicDescription) throws {
        try watch.run(.reading(url)) { try decoder.setOutputFormat(format) }
    }

    func seek(toFrame frame: Int64) throws {
        try watch.run(.seeking(url)) { try decoder.seek(toFrame: frame) }
    }

    func read(into buffer: UnsafeMutableRawPointer, frames: UInt32) throws -> UInt32 {
        try watch.run(.reading(url)) { try decoder.read(into: buffer, frames: frames) }
    }
}
