import Foundation
import Settings
import Testing

@testable import Library

/// A Gregorian calendar in `zone` whose weeks start on `firstWeekday`.
private func calendar(_ zone: String = "America/Los_Angeles", firstWeekday: Int = 1) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    calendar.firstWeekday = firstWeekday
    return calendar
}

/// The seconds of a local time in `calendar`.
private func seconds(
    _ calendar: Calendar, _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0,
    _ minute: Int = 0
) -> Int64 {
    let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
    return Int64(calendar.date(from: components)!.timeIntervalSince1970)
}

private func path(
    _ id: Int64, plays: Int, artist: Int64? = nil, album: Int64? = nil, genre: Int64? = nil,
    seconds: Double? = 200, codec: String = "flac", rate: Int = 44_100, inLibrary: Bool = true
) -> PeriodScan.Path {
    PeriodScan.Path(
        id: id, plays: plays, inLibrary: inLibrary, artistID: artist, albumID: album,
        genreID: genre, seconds: seconds, codec: codec, sampleRateHz: rate)
}

/// A scan of `span` with plays at `times`, each its own bucket of an hour.
private func scan(
    _ span: PlaySpan?, paths: [PeriodScan.Path] = [], times: [Int64] = [], bucket: Int64 = 3600,
    libraryTracks: Int = 100, undated: Int = 0
) -> PeriodScan {
    let buckets = Dictionary(grouping: times) { $0 / bucket * bucket }
        .map { PeriodScan.Bucket(start: $0.key, plays: $0.value.count) }
        .sorted { $0.start < $1.start }
    return PeriodScan(
        span: span, paths: paths, buckets: buckets, bucketSeconds: bucket,
        libraryTracks: libraryTracks, undatedPlays: undated)
}

@Test func totalsCountThePeriodsPlaysAndThoseNoLongerInTheLibrary() {
    let paths = [
        path(1, plays: 3, artist: 10, album: 20, genre: 30, seconds: 100),
        path(
            2, plays: 1, artist: 10, album: 21, genre: 30, seconds: 300, codec: "dsd",
            rate: 2_822_400),
        path(3, plays: 2, artist: 11, album: 22, seconds: 60, codec: "aac", rate: 44_100),
        path(4, plays: 4, seconds: 50, codec: "flac", rate: 96_000, inLibrary: false),
    ]
    let report = StatsReport(
        scan(nil, paths: paths, libraryTracks: 8, undated: 7), firstPlays: FirstPlays(),
        calendar: calendar())
    #expect(report.plays == 10)
    #expect(report.seconds == 300 + 300 + 120 + 200)
    #expect(report.tracks == 4)
    #expect(report.artists == 2)
    #expect(report.albums == 3)
    #expect(report.playedLibraryTracks == 3)
    #expect(report.libraryShare == 3.0 / 8)
    #expect(report.missingPlays == 4)
    #expect(report.undatedPlays == 7)
    #expect(report.codecs.map(\.name) == ["FLAC", "AAC", "DSD"])
    #expect(report.codecs.map(\.plays) == [7, 2, 1])
    #expect(report.rateGroups.map(\.name) == ["CD quality", "Hi-res PCM", "DSD", "Lossy"])
    #expect(report.rateGroups.map(\.plays) == [3, 4, 1, 2])
}

@Test func topListsRankByPlaysOrByHoursAndKeepMissingPlays() {
    let paths = [
        path(1, plays: 5, artist: 10, album: 20, genre: 30, seconds: 60),
        path(2, plays: 2, artist: 11, album: 21, genre: 31, seconds: 600),
        path(3, plays: 1, artist: 11, album: 21, genre: 31, seconds: 100),
        path(4, plays: 3, seconds: 10, inLibrary: false),
    ]
    let report = StatsReport(
        scan(nil, paths: paths), firstPlays: FirstPlays(), calendar: calendar())
    // A tie on plays goes to the one with more hours.
    #expect(report.list(.artists, by: .plays).map(\.id) == [10, 11, nil])
    #expect(report.list(.artists, by: .plays).map(\.plays) == [5, 3, 3])
    #expect(report.list(.artists, by: .hours).map(\.id) == [11, 10, nil])
    #expect(report.list(.artists, by: .hours).first?.seconds == 1300)
    #expect(report.list(.tracks, by: .plays).map(\.id) == [1, 4, 2, 3])
    #expect(report.list(.tracks, by: .plays)[1].inLibrary == false)
    #expect(report.list(.genres, by: .plays).map(\.id) == [30, 31, nil])
    // Save as Playlist: the listed artists' tracks still in the library, in the list's order.
    #expect(report.trackIDs(of: report.list(.artists, by: .hours), in: .artists) == [2, 3, 1])
    #expect(report.trackIDs(of: report.list(.tracks, by: .plays), in: .tracks) == [1, 2, 3])
}

@Test func namesFillTheListsAndSayWhatIsMissing() {
    let paths = [path(1, plays: 1, artist: 10, album: 20), path(4, plays: 1, inLibrary: false)]
    var report = StatsReport(
        scan(nil, paths: paths), firstPlays: FirstPlays(), calendar: calendar())
    #expect(report.namedIDs[.artists] == [10])
    #expect(report.namedIDs[.tracks] == [1, 4])
    report.name([
        .artists: [10: StatsName(name: "Nina")],
        .albums: [20: StatsName(name: "Blue", detail: "Nina")],
        .tracks: [1: StatsName(name: "One", detail: "Nina"), 4: StatsName(name: "gone")],
    ])
    #expect(report.list(.artists, by: .plays).map(\.name) == ["Nina", missingText])
    #expect(report.list(.albums, by: .plays).first?.detail == "Nina")
    #expect(report.list(.tracks, by: .plays).map(\.name) == ["One", "gone"])
    #expect(report.list(.tracks, by: .plays).map(\.detail) == ["Nina", missingText])
}

@Test func aPlayAtOneMinuteToMidnightAndOneAfterAreOnTwoDays() {
    let calendar = calendar()
    let span = PlaySpan(
        start: seconds(calendar, 2026, 3, 1), end: seconds(calendar, 2026, 3, 8))
    let late = seconds(calendar, 2026, 3, 2, 23, 59)
    let early = seconds(calendar, 2026, 3, 3, 0, 1)
    let report = StatsReport(
        scan(span, times: [late, early, early + 60]), firstPlays: FirstPlays(), calendar: calendar)
    #expect(report.barUnit == .day)
    #expect(report.bars.count == 7)
    #expect(report.bars.map(\.plays) == [0, 1, 2, 0, 0, 0, 0])
    #expect(
        report.bars[1].span
            == PlaySpan(start: seconds(calendar, 2026, 3, 2), end: seconds(calendar, 2026, 3, 3)))
    // Monday 23:00 and Tuesday 00:00, weekdays 2 and 3.
    #expect(report.weekdayHours[1][23] == 1)
    #expect(report.weekdayHours[2][0] == 2)
    #expect(report.busiestDay?.span.start == seconds(calendar, 2026, 3, 3))
    #expect(report.busiestDay?.plays == 2)
}

@Test func aDaylightSavingDayHasItsHoursAtTheNewOffset() {
    let calendar = calendar()
    // Los Angeles springs forward at 02:00 on Sunday 8 March 2026: that day has 23 hours.
    let span = PlaySpan(start: seconds(calendar, 2026, 3, 8), end: seconds(calendar, 2026, 3, 9))
    #expect(span.end - span.start == 23 * 3600)
    let beforeChange = seconds(calendar, 2026, 3, 8, 1, 30)
    let afterChange = beforeChange + 3600
    let evening = seconds(calendar, 2026, 3, 8, 23, 30)
    let report = StatsReport(
        scan(span, times: [beforeChange, afterChange, evening]), firstPlays: FirstPlays(),
        calendar: calendar)
    #expect(report.bars.map(\.plays) == [3])
    #expect(report.weekdayHours[0][1] == 1)
    #expect(report.weekdayHours[0][2] == 0)
    #expect(report.weekdayHours[0][3] == 1)
    #expect(report.weekdayHours[0][23] == 1)
    // And falls back on 1 November: 01:30 comes twice, both in hour 1 of that Sunday.
    let fallback = seconds(calendar, 2026, 11, 1, 0, 30) + 3600
    let twice = scan(nil, times: [fallback, fallback + 3600])
    let autumn = StatsReport(twice, firstPlays: FirstPlays(), calendar: calendar)
    #expect(autumn.weekdayHours[0][1] == 2)
}

@Test func aZoneWithHalfHourOffsetsCountsQuarterHours() {
    let india = calendar("Asia/Kolkata")
    let now = Date(timeIntervalSince1970: TimeInterval(seconds(india, 2026, 6, 1)))
    #expect(bucketSeconds(in: india.timeZone, around: nil, now: now) == 900)
    #expect(bucketSeconds(in: calendar().timeZone, around: nil, now: now) == 3600)
    // 00:15 in Kolkata is 18:45 UTC the day before: the bucket must not cross local midnight.
    let play = seconds(india, 2026, 6, 2, 0, 15)
    let report = StatsReport(
        scan(nil, times: [play], bucket: 900), firstPlays: FirstPlays(), calendar: india)
    #expect(report.weekdayHours[2][0] == 1)
    #expect(report.busiestDay?.span.start == seconds(india, 2026, 6, 2))
}

@Test func aYearsWeeksAreCutAtTheYearsEnds() {
    let calendar = calendar(firstWeekday: 2)
    let span = PlaySpan(start: seconds(calendar, 2025, 1, 1), end: seconds(calendar, 2026, 1, 1))
    let eve = seconds(calendar, 2025, 12, 31, 23, 59)
    let report = StatsReport(scan(span, times: [eve]), firstPlays: FirstPlays(), calendar: calendar)
    #expect(report.barUnit == .week)
    #expect(report.bars.first?.span.start == span.start)
    #expect(report.bars.last?.span.end == span.end)
    #expect(report.bars.last?.plays == 1)
    // Wednesday 1 January to Sunday 5 January is the first, cut, week.
    #expect(report.bars.first?.span.end == seconds(calendar, 2025, 1, 6))
    #expect(report.months.count == 12)
    #expect(report.busiestMonth?.span.start == seconds(calendar, 2025, 12, 1))
}

@Test func allTimeBarsRunFromTheFirstPlayToTheLast() {
    let calendar = calendar()
    let times = [seconds(calendar, 2020, 5, 3, 12), seconds(calendar, 2024, 2, 9, 12)]
    let report = StatsReport(scan(nil, times: times), firstPlays: FirstPlays(), calendar: calendar)
    #expect(report.barUnit == .month)
    #expect(report.bars.count == 46)
    #expect(report.bars.first?.span.start == times[0] / 3600 * 3600)
    #expect(report.bars.map(\.plays).reduce(0, +) == 2)
}

@Test func firstPlayedListsWhatTheHistoryHadNotPlayedBefore() {
    let calendar = calendar()
    let span = PlaySpan(start: seconds(calendar, 2026, 1, 1), end: seconds(calendar, 2027, 1, 1))
    let paths = [
        path(1, plays: 2, artist: 10, album: 20),
        path(2, plays: 1, artist: 10, album: 21),
        path(3, plays: 1, artist: 11, album: 22),
    ]
    var first = FirstPlays()
    // Album 20 and artist 10 were played last year; 21, 22 and 11 first this year.
    first.albums = [20: span.start - 10, 21: span.start + 50, 22: span.start + 20]
    first.artists = [10: span.start - 10, 11: span.start + 20]
    let report = StatsReport(scan(span, paths: paths), firstPlays: first, calendar: calendar)
    #expect(report.firstAlbums.map(\.id) == [22, 21])
    #expect(report.firstAlbums.map(\.firstPlayed) == [span.start + 20, span.start + 50])
    #expect(report.firstAlbumCount == 2)
    #expect(report.firstArtists.map(\.id) == [11])
    #expect(report.firstArtists.first?.plays == 1)
    // All Time's first plays are every album's.
    let all = StatsReport(scan(nil, paths: paths), firstPlays: first, calendar: calendar)
    #expect(all.firstAlbums.map(\.id) == [20, 22, 21])
}

// MARK: Against an index

@Test func theReaderReportsAPeriodFromTheHistory() async throws {
    let library = try TestLibrary()
    _ = try library.scan()
    let index = try library.index()
    let rows = try index.rows(ids: try index.trackIDs(sortedBy: .path))
    let calendar = calendar()
    let now = Date(timeIntervalSince1970: TimeInterval(seconds(calendar, 2026, 11, 5, 12)))
    let thisMonth = Double(seconds(calendar, 2026, 11, 2, 9))
    let lastMonth = Double(seconds(calendar, 2026, 10, 20, 9))
    try index.recordPlay(rows[0].path, at: lastMonth)
    try index.recordPlay(rows[0].path, at: thisMonth)
    try index.recordPlay(rows[0].path, at: thisMonth + 300)
    try index.recordPlay(rows[1].path, at: thisMonth + 600)
    try index.recordPlay("/elsewhere/never-indexed.flac", at: thisMonth + 900)
    // An import's plays, which have no history rows.
    try index.database.execute(
        "INSERT OR IGNORE INTO plays (path_id, play_count, skip_count) VALUES (\(rows[2].id), 4, 0)"
    )

    let reader = try StatsReader(databaseURL: library.databaseURL)
    let month = try await reader.report(
        .month, groupByAlbumArtist: false, now: now, calendar: calendar)
    #expect(month.plays == 4)
    #expect(month.tracks == 3)
    #expect(month.missingPlays == 1)
    #expect(month.undatedPlays == 0)
    #expect(month.playedLibraryTracks == 2)
    #expect(month.libraryTracks == rows.count)
    let top = month.list(.tracks, by: .plays)
    #expect(top.first?.id == rows[0].id)
    #expect(top.first?.plays == 2)
    #expect(top.first?.name == rows[0].title)
    #expect(top.last?.name == "never-indexed")
    #expect(top.last?.detail == missingText)
    let seconds0 = rows[0].durationSeconds
    let seconds1 = rows[1].durationSeconds
    #expect(abs(month.seconds - (2 * seconds0 + seconds1)) < 0.01)
    #expect(month.bars.map(\.plays).reduce(0, +) == 4)
    // rows[0]'s album was first played last month, so it isn't new this month.
    let firstAlbum = try #require(rows[0].albumID)
    #expect(!month.firstAlbums.contains { $0.id == firstAlbum })

    let all = try await reader.report(.all, groupByAlbumArtist: false, now: now, calendar: calendar)
    #expect(all.plays == 5)
    #expect(all.undatedPlays == 4)
    #expect(all.firstAlbums.first?.firstPlayed == Int64(lastMonth))

    // A new play, through another connection, is in the next report.
    try index.recordPlay(rows[3].path, at: thisMonth + 1200)
    let again = try await reader.report(
        .month, groupByAlbumArtist: false, now: now, calendar: calendar)
    #expect(again.plays == 5)
}

@Test func eachImportsLastPlayIsOneDatedPlayAndTheRestStayUndated() async throws {
    let library = try TestLibrary()
    _ = try library.scan()
    let index = try library.index()
    let rows = try index.rows(ids: try index.trackIDs(sortedBy: .path))
    let calendar = calendar()
    let now = Date(timeIntervalSince1970: TimeInterval(seconds(calendar, 2026, 11, 5, 12)))
    let thisMonth = Double(seconds(calendar, 2026, 11, 2, 9))
    let lastYear = Double(seconds(calendar, 2025, 6, 14, 21))
    var swinsian = PlayerLibrary(player: .swinsian, source: "/swinsian/Library.sqlite")
    for (row, plays, played) in [
        (rows[0], 2, thisMonth - 50), (rows[1], 5, thisMonth + 100), (rows[2], 3, lastYear),
        // Swinsian's date with no play counted is no play.
        (rows[3], 0, thisMonth),
    ] {
        var track = PlayerTrack(path: row.path)
        track.plays = plays
        track.lastPlayedSeconds = played
        _ = swinsian.add(track)
    }
    _ = try index.applyImport(swinsian, prefix: nil)
    // Played here after Swinsian last played it: both plays have dates.
    try index.recordPlay(rows[0].path, at: thisMonth)

    let reader = try StatsReader(databaseURL: library.databaseURL)
    let month = try await reader.report(
        .month, groupByAlbumArtist: false, now: now, calendar: calendar)
    #expect(month.plays == 3)
    #expect(month.importedPlays == 2)
    #expect(month.tracks == 2)
    #expect(month.list(.tracks, by: .plays).map(\.id) == [rows[0].id, rows[1].id])
    #expect(month.list(.tracks, by: .plays).first?.plays == 2)
    #expect(month.bars.map(\.plays).reduce(0, +) == 3)
    #expect(month.weekdayHours.joined().reduce(0, +) == 3)

    let all = try await reader.report(.all, groupByAlbumArtist: false, now: now, calendar: calendar)
    #expect(all.plays == 4)
    #expect(all.importedPlays == 3)
    // 1 + 2 + 5 + 3 counted, 4 with dates.
    #expect(all.undatedPlays == 7)
    #expect(all.earliestPlay == Int64(lastYear))
    let lastYearsAlbum = try #require(rows[2].albumID)
    #expect(all.firstAlbums.first { $0.id == lastYearsAlbum }?.firstPlayed == Int64(lastYear))
    let year = try await reader.report(
        .chosenYear(2025), groupByAlbumArtist: false, now: now, calendar: calendar)
    #expect(year.plays == 1 && year.importedPlays == 1)
    #expect(year.firstAlbums.contains { $0.id == lastYearsAlbum })
}

@Test func theStatsSourceListsThePeriodsTracksAndTheTimelineItsSpan() throws {
    let library = try TestLibrary()
    _ = try library.scan()
    let index = try library.index()
    let rows = try index.rows(ids: try index.trackIDs(sortedBy: .path))
    let now = Date().timeIntervalSince1970
    try index.recordPlay(rows[0].path, at: now - 86_400 * 800)
    try index.recordPlay(rows[1].path, at: now - 60)
    try index.recordPlay(rows[2].path, at: now - 30)
    let thisYear = try index.trackIDs(
        TrackFilter(source: .stats(.year)), sortedBy: .path, ascending: true)
    #expect(Set(thisYear) == [rows[1].id, rows[2].id])
    let allTime = try index.trackIDs(
        TrackFilter(source: .stats(.all)), sortedBy: .path, ascending: true)
    #expect(Set(allTime) == [rows[0].id, rows[1].id, rows[2].id])
    // An import's last play puts its track in the period, as a play would.
    var swinsian = PlayerLibrary(player: .swinsian, source: "/swinsian/Library.sqlite")
    for (row, played) in [(rows[5], now - 120), (rows[6], now - 86_400 * 800)] {
        var track = PlayerTrack(path: row.path)
        track.plays = 4
        track.lastPlayedSeconds = played
        _ = swinsian.add(track)
    }
    _ = try index.applyImport(swinsian, prefix: nil)
    #expect(
        Set(
            try index.trackIDs(TrackFilter(source: .stats(.year)), sortedBy: .path, ascending: true)
        )
            == [rows[1].id, rows[2].id, rows[5].id])
    #expect(
        Set(try index.trackIDs(TrackFilter(source: .stats(.all)), sortedBy: .path, ascending: true))
            == [rows[0].id, rows[1].id, rows[2].id, rows[5].id, rows[6].id])
    #expect(throws: LibraryError.self) {
        try index.trackIDs(
            TrackFilter(source: .plays(PlaySpan(start: 0, end: 1))), sortedBy: .path,
            ascending: true)
    }

    let span = PlaySpan(start: Int64(now) - 100, end: Int64(now))
    let page = try index.timeline(before: nil, limit: 200, in: span)
    #expect(page.map(\.trackID) == [rows[2].id, rows[1].id])
    #expect(
        try index.timeline(before: page.first?.id, limit: 200, in: span).map(\.trackID) == [
            rows[1].id
        ])
    #expect(try index.playCount(in: span) == 2)
    try index.recordPlay(rows[3].path, at: now - 10_000)
    try index.recordPlay(rows[4].path, at: now - 5)
    #expect(
        try index.timeline(after: try #require(page.first?.id), limit: 200, in: span).map(\.trackID)
            == [rows[4].id])
}
