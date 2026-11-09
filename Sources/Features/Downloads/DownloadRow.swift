import DisplayText
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
    /// The Soulseek folder chosen: its peer and size; empty before one is.
    var candidate: String
    /// For an upgrade, what it replaces, for the source's tooltip.
    var replaces: String?
    /// The state in words.
    var state: String
    /// More about the state, for its tooltip: the search's query and the attempt.
    var stateDetail: String?
    /// From 0 to 1 while downloading or copying into staging, for the progress bar.
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
    /// `answering` is false while the service doesn't answer, which dims every row; `rate` is
    /// the speed of the bytes it's moving, while the window shows one; `formatted` words the
    /// time of the next search.
    init?(
        _ job: DownloadJob, machine: String, answering: Bool = true, rate: TransferRate? = nil,
        formatted: (Date) -> String = DownloadRow.shortTime
    ) {
        guard let group = Self.group(job.state) else { return nil }
        id = job.id
        source = job.source
        album = Self.album(job.release)
        releaseID = job.release.releaseID
        format = Self.format(job)
        candidate = Self.candidate(job)
        replaces = job.upgrade.map { "Replaces \($0.currentQuality)" }
        state = Self.state(job, formatted: formatted)
        if Self.isTransferring(job.state), let rate { state += " · " + rate.text }
        stateDetail = Self.stateDetail(job)
        progress = Self.isTransferring(job.state) ? job.progress.map(Self.fraction) : nil
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

    /// "Nov 10, 4:42 PM": how a row words the time of the next search.
    static func shortTime(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
    }

    /// Whether `state` moves bytes the service reports in `progress`: slskd's download, or the
    /// copy into staging.
    static func isTransferring(_ state: JobState) -> Bool {
        state == .downloading || state == .downloaded
    }

    /// The state in words, with the service's reason where it gave one. A search says how far
    /// its query has got, and a search after a miss says what the last one found; a job not
    /// found says when it searches next, through `formatted`.
    static func state(_ job: DownloadJob, formatted: (Date) -> String = shortTime) -> String {
        let lastTime = job.reason.map { "; last time: \($0)" } ?? ""
        let again = job.attempt > 1
        let words: String
        switch job.state {
        case .queued:
            return again ? "Queued to search again" + lastTime : "Queued"
        case .searching:
            guard let search = job.search else {
                return (again ? "Searching again…" : "Searching…") + lastTime
            }
            let query =
                search.queryCount > 1
                ? ", query \(search.queryNumber) of \(search.queryCount)" : ""
            let answers =
                search.peers == 0
                ? "no answers yet"
                : "\(count(search.peers, "peer")), \(count(search.files, "file"))"
            return (again ? "Searching again" : "Searching") + query + ": " + answers + lastTime
        case .notFound:
            let next =
                job.nextAttemptAt.map {
                    "; searching again \(formatted(Date(timeIntervalSince1970: TimeInterval($0))))"
                } ?? "; Retry searches again"
            return "Not found" + (job.reason.map { ": \($0)" } ?? "") + next
        case .candidateFound: words = "Found, starting the download"
        case .downloading:
            words =
                job.progress.map { "Downloading, \($0.filesDone) of \($0.filesTotal) files" }
                ?? "Downloading"
        case .downloaded:
            words =
                job.progress.map {
                    "Copying to staging, \($0.filesDone) of \($0.filesTotal) files"
                } ?? "Copying to staging…"
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

    /// The running query and, from the second search on, the attempt, for the state's
    /// tooltip; nil when there's neither.
    static func stateDetail(_ job: DownloadJob) -> String? {
        var lines: [String] = []
        if job.state == .searching, let search = job.search {
            lines.append("Searching Soulseek for \"\(search.query)\"")
        }
        if [.queued, .searching, .notFound].contains(job.state), job.attempt > 1 {
            lines.append("Attempt \(job.attempt)")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
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

    /// "made-up-peer, 53 MB": who the folder is from and how big it is.
    static func candidate(_ job: DownloadJob) -> String {
        guard let found = job.candidate else { return "" }
        let size = ByteCountFormatter.string(
            fromByteCount: Int64(found.bytes), countStyle: .file)
        return "\(found.peer), \(size)"
    }

    static func policyName(_ policy: FormatPolicy) -> String {
        switch policy {
        case .flac: "FLAC"
        case .lossless: "Lossless"
        case .mp3320: "MP3 320"
        case .any: "Any format"
        }
    }

    /// "Discogs release 4242", as the window and its sheets name a release.
    static func releaseName(_ id: Int) -> String { "Discogs release \(id)" }

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
