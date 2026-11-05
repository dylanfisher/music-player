import Foundation
import Log
import Settings

/// Listening Stats' reads, on a read-only connection of their own so the window's queries
/// never wait for a period's scans (ADR 0102). It keeps every album's and artist's first play,
/// one scan of the whole history, until another connection commits a change.
public actor StatsReader {
    private let index: LibraryIndex
    private var firstPlays: (version: Int, groupByAlbumArtist: Bool, plays: FirstPlays)?

    public init(databaseURL: URL) throws {
        index = try LibraryIndex(at: databaseURL)
        try index.database.execute("PRAGMA query_only = ON")
    }

    /// The report of `period` at `now` in `calendar`, its artists grouped as the Artists
    /// column groups them.
    public func report(
        _ period: StatsPeriod, groupByAlbumArtist: Bool, now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> StatsReport {
        try signposted(.query) {
            let span = period.span(now: now, calendar: calendar)
            let scan = try index.periodScan(
                span, groupByAlbumArtist: groupByAlbumArtist,
                bucketSeconds: bucketSeconds(in: calendar.timeZone, around: span, now: now))
            var report = StatsReport(
                scan, firstPlays: try firstPlays(groupByAlbumArtist: groupByAlbumArtist),
                calendar: calendar)
            report.name(try index.statsNames(report.namedIDs))
            return report
        }
    }

    /// The first plays, read again when the library changed since they were or the artists
    /// are grouped another way.
    private func firstPlays(groupByAlbumArtist: Bool) throws -> FirstPlays {
        let version = try index.dataVersion()
        if let firstPlays, firstPlays.version == version,
            firstPlays.groupByAlbumArtist == groupByAlbumArtist
        {
            return firstPlays.plays
        }
        let plays = try index.firstPlays(groupByAlbumArtist: groupByAlbumArtist)
        firstPlays = (version, groupByAlbumArtist, plays)
        return plays
    }
}
