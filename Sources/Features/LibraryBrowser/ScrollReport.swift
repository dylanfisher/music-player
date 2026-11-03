import Foundation
import Settings

/// What the track table scrolls through for `MusicPlayer --measure-scroll` (ADR 0073).
public enum ScrollCase: String, CaseIterable, Sendable {
    /// Trackpad flicks down the list.
    case trackpad
    /// The same, while the browser hears a scan's progress and refreshes as during a scan.
    case scan
    /// No flicks: Page Down a screenful at a time, each once the screen's art has arrived.
    case pages
}

/// What `MusicPlayer --measure-scroll` prints as one JSON line and Bench reads (ADR 0073).
public struct ScrollReport: Codable, Equatable, Sendable {
    /// The main thread's busy time in each frame of the scroll, in milliseconds.
    public var framesMs: [Double]
    /// The busy time of each frame a refresh for a library change landed in.
    public var refreshFramesMs: [Double]
    /// From a page down after the last frame until every row on screen showed its art, in
    /// milliseconds; nil when that took longer than the measurement waits.
    public var lastCoverMs: Double?
    /// Art reads from files during the scroll.
    public var artReads: Int
    /// For each page down, the milliseconds until every row on screen showed its art.
    public var pageCoversMs: [Double]

    public init(
        framesMs: [Double], refreshFramesMs: [Double], lastCoverMs: Double?, artReads: Int,
        pageCoversMs: [Double]
    ) {
        self.framesMs = framesMs
        self.refreshFramesMs = refreshFramesMs
        self.lastCoverMs = lastCoverMs
        self.artReads = artReads
        self.pageCoversMs = pageCoversMs
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case framesMs, refreshFramesMs, lastCoverMs, artReads, pageCoversMs
    }

    /// Rejects a key it doesn't know, so a renamed field fails instead of reading as missing.
    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(decoder, CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        framesMs = try container.decode([Double].self, forKey: .framesMs)
        refreshFramesMs = try container.decode([Double].self, forKey: .refreshFramesMs)
        lastCoverMs = try container.decodeIfPresent(Double.self, forKey: .lastCoverMs)
        artReads = try container.decode(Int.self, forKey: .artReads)
        pageCoversMs = try container.decode([Double].self, forKey: .pageCoversMs)
    }
}
