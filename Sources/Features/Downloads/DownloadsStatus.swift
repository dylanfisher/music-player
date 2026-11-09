import DisplayText
import Foundation
import Recommender
import Settings

/// What the status bar's downloads item says: the albums on their way to the staging folder,
/// how far they've got together, and a line each for its tooltip. Worked out from the jobs
/// alone, so the item only draws it.
struct DownloadsStatus: Equatable, Sendable {
    /// "Artist - Title (year): its state", a line each, in the window's order.
    var lines: [String]
    /// How far the albums have got, from 0 to 1: a search counts as none, the download by its
    /// bytes, the copy into staging as the download done.
    var fraction: Double

    var albums: Int { lines.count }

    /// The status of `jobs`; nil when none is on its way, and the item hides.
    init?(_ jobs: some Sequence<DownloadJob>) {
        let going = jobs.filter(DownloadsModel.isOnItsWay)
            .sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
        guard !going.isEmpty else { return nil }
        lines = going.map { "\(DownloadRow.album($0.release)): \(DownloadRow.state($0))" }
        fraction =
            going.map { job -> Double in
                switch job.state {
                case .downloading: job.progress.map(DownloadRow.fraction) ?? 0
                case .downloaded: 1
                default: 0
                }
            }.reduce(0, +) / Double(going.count)
    }

    /// "45%".
    var percent: String { "\(Int((fraction * 100).rounded(.down)))%" }

    /// The item's text in `style`: the count alone beside the symbol or the bar, or a line.
    func text(_ style: DownloadsStatusStyle) -> String {
        switch style {
        case .count, .progress: number(albums)
        case .text: "Downloading \(count(albums, "album")), \(percent)"
        }
    }

    /// The albums and what each is doing, then what a click and a right-click do.
    var tooltip: String {
        (lines + ["", "Click to open Downloads. Right-click to choose how this shows."])
            .joined(separator: "\n")
    }
}
