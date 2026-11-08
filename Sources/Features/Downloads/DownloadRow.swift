import Foundation
import Recommender

/// One job as the Downloads window lists it, worked out from the job and this Mac's name
/// alone. The rules are static functions, table-tested, so the window only draws them.
struct DownloadRow: Equatable, Sendable {
    /// How the row is drawn.
    struct Style: Equatable, Sendable {
        /// Secondary text at half alpha: the job is still on its way to the staging folder,
        /// or the service didn't answer and the row is as it last was.
        var isDimmed: Bool
        /// The state in red, with its reason.
        var isFailed: Bool
        /// The tagging cell warns: a discrepancy or an error. The rest of the row doesn't.
        var warnsTagging: Bool
    }

    /// The window's sections, in their order; newest first within each.
    enum Group: Int, Comparable, Sendable {
        case needsReview, downloading, waiting, failed

        static func < (a: Group, b: Group) -> Bool { a.rawValue < b.rawValue }
    }

    /// What the player reported of its tag run, for the Tagging column.
    struct Tagging: Equatable, Sendable {
        var status: DownloadJob.Tagging.Status
        /// For a discrepancy or an error, the tooltip's lines.
        var reasons: [String]
        /// "Pending", "Tagging", "Clean", "Discrepancy" or "Error"; empty before the job is
        /// staged, when there's nothing to tag yet.
        var label: String
    }

    var id: Int
    var source: DownloadJob.Source
    /// "Artist - Title (year)".
    var album: String
    /// For the album's tooltip.
    var releaseID: Int
    /// The policy, and once a folder is chosen what it holds.
    var format: String
    /// The state in words.
    var state: String
    /// From 0 to 1 while downloading, for the progress bar.
    var progress: Double?
    var tagging: Tagging
    var added: Date
    var style: Style
    /// "Being reviewed on <Mac>" while another Mac holds the review claim, which disables the
    /// row's actions here.
    var claimedElsewhere: String?
    var group: Group
    var canApprove: Bool

    /// `job`'s row on the Mac named `machine`; nil for a terminal job, which isn't listed.
    /// `answering` is false while the service doesn't answer, which dims every row.
    init?(_ job: DownloadJob, machine: String, answering: Bool = true) {
        guard let group = Self.group(job.state) else { return nil }
        id = job.id
        source = job.source
        album = Self.album(job.release)
        releaseID = job.release.releaseID
        format = Self.format(job)
        state = Self.state(job)
        progress = job.state == .downloading ? job.progress.map(Self.fraction) : nil
        tagging = Self.tagging(job.tagging, state: job.state)
        added = Date(timeIntervalSince1970: TimeInterval(job.createdAt))
        style = Self.style(
            job.state, failedStage: job.failedStage, tagging: job.tagging.status,
            answering: answering)
        claimedElsewhere = Self.claimedElsewhere(job.review, machine: machine)
        self.group = group
        canApprove =
            answering
            && Self.canApprove(
                job.state, tagging: job.tagging.status, review: job.review, machine: machine)
    }

    /// Dimmed through `downloading`, and a failed job the service retries from its search or
    /// download, since none of them has files to look at yet; opaque from `downloaded` on.
    static func style(
        _ state: JobState, failedStage: DownloadJob.FailedStage?,
        tagging: DownloadJob.Tagging.Status, answering: Bool
    ) -> Style {
        let onTheWay: Bool =
            switch state {
            case .queued, .searching, .notFound, .candidateFound, .downloading: true
            case .failed: failedStage == .search || failedStage == .download
            case .downloaded, .staged, .approved, .importing, .imported, .rejected, .cancelled:
                false
            }
        return Style(
            isDimmed: onTheWay || !answering, isFailed: state == .failed,
            warnsTagging: tagging == .discrepancy || tagging == .error)
    }

    /// The section `state` is listed in; nil for a terminal state, which isn't listed.
    static func group(_ state: JobState) -> Group? {
        switch state {
        case .staged, .approved, .importing: .needsReview
        case .candidateFound, .downloading, .downloaded: .downloading
        case .queued, .searching, .notFound: .waiting
        case .failed: .failed
        case .imported, .rejected, .cancelled: nil
        }
    }

    /// Approve is enabled for a staged job tagged clean whose review claim this Mac holds.
    static func canApprove(
        _ state: JobState, tagging: DownloadJob.Tagging.Status, review: DownloadJob.Hold?,
        machine: String
    ) -> Bool {
        state == .staged && tagging == .clean && review?.machine == machine
    }

    /// "Being reviewed on <Mac>" when a Mac other than `machine` holds `review`.
    static func claimedElsewhere(_ review: DownloadJob.Hold?, machine: String) -> String? {
        guard let review, review.machine != machine else { return nil }
        return "Being reviewed on \(review.machine)"
    }

    static func tagging(_ tagging: DownloadJob.Tagging, state: JobState) -> Tagging {
        let tagged: Bool =
            switch state {
            case .staged, .approved, .importing, .imported: true
            case .failed, .rejected, .cancelled: tagging.status != .none
            case .queued, .searching, .notFound, .candidateFound, .downloading, .downloaded:
                false
            }
        let label: String =
            switch tagging.status {
            case .none: "Pending"
            case .running: "Tagging"
            case .clean: "Clean"
            case .discrepancy: "Discrepancy"
            case .error: "Error"
            }
        return Tagging(
            status: tagging.status, reasons: tagging.reasons, label: tagged ? label : "")
    }

    /// The state in words, with the service's reason where it gave one.
    static func state(_ job: DownloadJob) -> String {
        let words: String
        switch job.state {
        case .queued: words = "Queued"
        case .searching: words = "Searching"
        case .notFound: words = "Not found"
        case .candidateFound: words = "Found, starting the download"
        case .downloading:
            words =
                job.progress.map { "Downloading, \($0.filesDone) of \($0.filesTotal) files" }
                ?? "Downloading"
        case .downloaded: words = "Downloaded"
        case .staged: words = "Staged"
        case .approved: words = "Approved"
        case .importing: words = "Importing"
        case .imported: words = "Imported"
        case .rejected: words = "Rejected"
        case .failed:
            words = job.failedStage.map { "Failed at \($0.rawValue)" } ?? "Failed"
        case .cancelled: words = "Cancelled"
        }
        return job.reason.map { "\(words): \($0)" } ?? words
    }

    /// The policy until a folder is chosen, then what it holds: "FLAC 16/44.1, 12 files".
    static func format(_ job: DownloadJob) -> String {
        guard let found = job.candidate else { return policyName(job.formatPolicy) }
        var words = found.format.rawValue.uppercased()
        if let depth = found.bitDepth, let rate = found.sampleRateHz {
            let khz = Double(rate) / 1000
            words += " \(depth)/" + (khz == khz.rounded() ? "\(Int(khz))" : "\(khz)")
        } else if let kbps = found.bitrateKbps {
            words += found.variableBitrate == true ? " VBR \(kbps) kbps" : " \(kbps) kbps"
        }
        return words + ", \(found.fileCount) file\(found.fileCount == 1 ? "" : "s")"
    }

    static func policyName(_ policy: FormatPolicy) -> String {
        switch policy {
        case .flac: "FLAC"
        case .lossless: "Lossless"
        case .mp3320: "MP3 320"
        case .any: "Any format"
        }
    }

    /// "Artist - Title (year)", without the year when the release has none.
    static func album(_ release: DownloadJob.Release) -> String {
        "\(release.artist) - \(release.title)" + (release.year.map { " (\($0))" } ?? "")
    }

    /// How much of the download is done, by bytes, from 0 to 1.
    static func fraction(_ progress: DownloadJob.Progress) -> Double {
        guard progress.bytesTotal > 0 else { return 0 }
        return min(1, Double(progress.bytesDone) / Double(progress.bytesTotal))
    }

    /// The window's order: by section, then newest first.
    static func listed(before a: DownloadRow, _ b: DownloadRow) -> Bool {
        if a.group != b.group { return a.group < b.group }
        if a.added != b.added { return a.added > b.added }
        return a.id > b.id
    }
}
