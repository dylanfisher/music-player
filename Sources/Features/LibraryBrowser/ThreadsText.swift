import DisplayText
import Foundation
import Recommender

/// What Threads says before Show Threads has given it a seed.
let threadsNoSeedText =
    "Choose Show Threads on an album to see the albums of yours connected to it."

/// The seed in the panel's header: "Made-Up Album – Made-Up Artist, 1997".
func threadsSeedTitle(_ seed: RediscoverDay.Album) -> String {
    terminalSafe("\(seed.title) – \(seed.artist)") + (seed.year.map { ", \($0)" } ?? "")
}

/// The Threads card's lines: All, then each thread of `reply` in the service's words, with
/// its albums' count. The count is of the albums the table lists, the service's ids `listed`,
/// so it matches the table.
func threadsRows(_ reply: AlbumThreads, listed: Set<String>) -> [StatsListView.Row] {
    let counts = reply.threads.map { $0.ids.filter(listed.contains).count }
    let most = max(1, listed.count)
    return [
        StatsListView.Row(rank: nil, name: "All", value: number(listed.count), fraction: 1)
    ]
        + zip(reply.threads, counts).map { thread, count in
            StatsListView.Row(
                rank: nil, name: terminalSafe(thread.words), value: number(count),
                fraction: Double(count) / Double(most), dimmed: count == 0)
        }
}

/// The selected album and the threads it's in, a thread a line.
func threadsAlbumText(_ album: RediscoverDay.Album, in threads: [RediscoverDay.Thread]) -> String {
    ([terminalSafe("\(album.artist) – \(album.title)")]
        + threads.map { "• " + terminalSafe($0.words) }).joined(separator: "\n")
}

/// What the Threads card says in place of the threads, or beside them.
func threadsProblemText(_ problem: ThreadsModel.Problem) -> String {
    switch problem {
    case .unknownAlbums(let unknown):
        return "\(count(unknown, "album")) of the threads aren't in this library, though its"
            + " profile was sent again. Refresh in a minute; if they stay, the service may be"
            + " keeping another Mac's profile."
    case .refused(let refusal) where refusal.code == .noSeed:
        return "The service's profile doesn't have this album, though this library's was sent"
            + " again. Refresh in a minute."
    case .refused(let refusal) where refusal.code == .untagged:
        return "The service's catalog doesn't have this album's Discogs release, so it's in no"
            + " thread."
    case .refused(let refusal) where refusal.code == .noCatalog: return noCatalogText
    default: return rediscoverProblemText(problem)
    }
}
