import DisplayText
import Foundation
import Recommender

/// How fast a job's bytes are moving, and how long the rest takes at that pace.
struct TransferRate: Equatable, Sendable {
    var bytesPerSecond: Double
    var secondsLeft: Double

    /// "2.4 MB/s, about 3 min left".
    var text: String { "\(fileSizeText(Int(bytesPerSecond)))/s, \(Self.left(secondsLeft))" }

    /// "less than a minute left", "about 3 min left", "about 1 h 5 min left": rounded up to
    /// the minute, since the estimate isn't finer than that.
    static func left(_ seconds: Double) -> String {
        guard seconds >= 60 else { return "less than a minute left" }
        let minutes = Int((seconds / 60).rounded(.up))
        guard minutes >= 60 else { return "about \(minutes) min left" }
        let rest = minutes % 60
        return "about \(minutes / 60) h" + (rest == 0 ? "" : " \(rest) min") + " left"
    }
}

/// The speed of each job downloading or copying into staging, from the bytes the service
/// reports and the times this Mac received them. The service rewrites a download's progress
/// about every 5 s and the copy's every 8 MB, and holds a download's still for up to about
/// 77 s while any job searches, so one reading says little: the speed is taken across the
/// last `readingsKept` readings whose bytes changed. A reading that stops changing keeps its
/// speed for `heldSeconds`, then shows none, never 0 B/s. The model feeds it only while the
/// window is open.
struct TransferRates: Sendable {
    /// Readings the speed is averaged over.
    static let readingsKept = 6
    /// The shortest time between the first and last reading a speed is taken over: polls 2 s
    /// apart of a value rewritten every 5 s would otherwise swing it by half.
    static let shortestSpanSeconds: TimeInterval = 8
    /// How long a speed holds after its bytes last moved: longer than a search's stall.
    static let heldSeconds: TimeInterval = 120

    private struct Reading: Sendable {
        var at: Date
        var bytes: Int
    }

    /// One job's readings in one state; a change of state or of total starts again, since the
    /// copy's bytes aren't the download's.
    private struct Transfer: Sendable {
        var state: JobState
        var totalBytes: Int
        var readings: [Reading]
    }

    private var transfers: [Int: Transfer] = [:]

    /// Takes the jobs a poll answered with at `now`. Only jobs moving bytes are kept.
    mutating func take(_ jobs: some Sequence<DownloadJob>, at now: Date) {
        var next: [Int: Transfer] = [:]
        for job in jobs where DownloadRow.isTransferring(job.state) {
            guard let progress = job.progress else { continue }
            var transfer =
                transfers[job.id].flatMap {
                    $0.state == job.state && $0.totalBytes == progress.bytesTotal ? $0 : nil
                } ?? Transfer(state: job.state, totalBytes: progress.bytesTotal, readings: [])
            if let last = transfer.readings.last, progress.bytesDone < last.bytes {
                transfer.readings = []
            }
            if transfer.readings.last?.bytes != progress.bytesDone {
                transfer.readings.append(Reading(at: now, bytes: progress.bytesDone))
                transfer.readings = Array(transfer.readings.suffix(Self.readingsKept))
            }
            next[job.id] = transfer
        }
        transfers = next
    }

    /// Forgets every reading, when nothing shows a speed.
    mutating func removeAll() { transfers = [:] }

    var isEmpty: Bool { transfers.isEmpty }

    /// The job `id`'s speed at `now`; nil before enough readings, once its bytes have stood
    /// still for `heldSeconds`, or for a job not moving bytes.
    func rate(_ id: Int, at now: Date) -> TransferRate? {
        guard let transfer = transfers[id], let first = transfer.readings.first,
            let last = transfer.readings.last
        else { return nil }
        let span = last.at.timeIntervalSince(first.at)
        guard span >= Self.shortestSpanSeconds, last.bytes > first.bytes,
            now.timeIntervalSince(last.at) <= Self.heldSeconds
        else { return nil }
        let speed = Double(last.bytes - first.bytes) / span
        return TransferRate(
            bytesPerSecond: speed,
            secondsLeft: Double(max(0, transfer.totalBytes - last.bytes)) / speed)
    }
}
