import Foundation
import Settings

/// Listening Stats for one period (ADR 0102): totals, top lists, plays over time and by the
/// hour of the week, what was first played and in which formats. Only plays with a date, rows
/// of `history`, are counted; All Time also says how many plays have none. Built from a
/// `PeriodScan` in local time: a play's day and hour are its bucket's at the time zone's offset
/// then, and the bars are the calendar's days, weeks, months or years.
public struct StatsReport: Equatable, Sendable {
    public enum List: String, CaseIterable, Sendable, Codable {
        case artists, albums, tracks, genres

        public var title: String {
            switch self {
            case .artists: "Top Artists"
            case .albums: "Top Albums"
            case .tracks: "Top Tracks"
            case .genres: "Top Genres"
            }
        }
    }

    /// What the top lists are ordered by.
    public enum Ranking: String, CaseIterable, Sendable, Codable {
        case plays, hours
    }

    /// A row of a top list or of what was first played. `id` is the artist's, album's, genre's
    /// or track's (a path ID), and nil on the row that adds up the plays of paths no longer in
    /// the library.
    public struct Entry: Equatable, Sendable, Codable {
        public var id: Int64?
        public var name = ""
        /// The album's artist, or the track's.
        public var detail: String?
        public var plays = 0
        public var seconds = 0.0
        /// False for plays of a path no longer in the library.
        public var inLibrary: Bool
        /// When it was first played, in seconds since 1970; set on the first played lists.
        public var firstPlayed: Int64?
    }

    /// The span a bar covers, and the plays in it.
    public struct Bar: Equatable, Sendable, Codable {
        public var span: PlaySpan
        public var plays: Int
    }

    /// What one bar of the plays over time covers.
    public enum BarUnit: String, Sendable, Codable {
        case day, week, month, year

        var component: Calendar.Component {
            switch self {
            case .day: .day
            case .week: .weekOfYear
            case .month: .month
            case .year: .year
            }
        }

        /// The unit that draws a range of `days` in a few dozen bars at most: days up to a
        /// month, weeks up to a year, months up to ten years.
        static func fitting(days: Int64) -> BarUnit {
            switch days {
            case ...32: .day
            case ...367: .week
            case ...3660: .month
            default: .year
            }
        }
    }

    /// The formats plays are grouped in by sample rate.
    public enum RateGroup: String, CaseIterable, Sendable, Codable {
        /// Lossless PCM at 48 kHz or less.
        case cdQuality
        /// Lossless PCM above 48 kHz.
        case hiRes
        case dsd
        /// AAC and MP3, at any rate.
        case lossy

        public var title: String {
            switch self {
            case .cdQuality: "CD quality"
            case .hiRes: "Hi-res PCM"
            case .dsd: "DSD"
            case .lossy: "Lossy"
            }
        }

        /// The group of a file of `codec` at `sampleRateHz`, as `paths` and `tracks` store them.
        static func of(codec: String, sampleRateHz: Int) -> RateGroup {
            switch codec {
            case "dsd": .dsd
            case "aac", "mp3": .lossy
            default: sampleRateHz > 48_000 ? .hiRes : .cdQuality
            }
        }
    }

    /// A codec or group and the plays in it.
    public struct Share: Equatable, Sendable, Codable {
        public var name: String
        public var plays: Int
    }

    /// How many rows each list keeps.
    public static let listLength = 25

    /// The period's bounds; nil for All Time.
    public var span: PlaySpan?
    public var plays = 0
    /// The plays' lengths added up: approximate, since a play is counted when most of a track
    /// was heard, not all of it.
    public var seconds = 0.0
    /// Distinct tracks played, those no longer in the library included.
    public var tracks = 0
    public var artists = 0
    public var albums = 0
    /// Tracks in the library now, and how many of them were played in the period.
    public var libraryTracks = 0
    public var playedLibraryTracks = 0
    /// Plays of paths no longer in the library, counted in the totals.
    public var missingPlays = 0
    /// Plays without a date, such as imported ones; only counted for All Time, and in no
    /// other total.
    public var undatedPlays = 0
    /// Each ranking's lists, `listLength` rows at most.
    public var top: [Ranking: [List: [Entry]]] = [:]
    public var barUnit = BarUnit.day
    public var bars: [Bar] = []
    /// The calendar months of the period, or of every play for All Time.
    public var months: [Bar] = []
    /// Plays by weekday and hour: `weekdayHours[weekday - 1][hour]`, weekday 1 being Sunday as
    /// `Calendar` numbers them.
    public var weekdayHours = Array(repeating: Array(repeating: 0, count: 24), count: 7)
    public var busiestDay: Bar?
    public var busiestMonth: Bar?
    /// Albums and artists whose first play with a date is in the period, earliest first,
    /// `listLength` rows at most, and how many there are.
    public var firstAlbums: [Entry] = []
    public var firstArtists: [Entry] = []
    public var firstAlbumCount = 0
    public var firstArtistCount = 0
    public var codecs: [Share] = []
    public var rateGroups: [Share] = []
    /// The first play with a date in the whole history, whatever the period.
    public var earliestPlay: Int64?
    /// The paths played, for the tracks of a list; not part of what the report shows.
    var paths: [PeriodScan.Path] = []

    /// The share of the library played, from 0 to 1.
    public var libraryShare: Double {
        libraryTracks == 0 ? 0 : Double(playedLibraryTracks) / Double(libraryTracks)
    }

    public func list(_ list: List, by ranking: Ranking) -> [Entry] { top[ranking]?[list] ?? [] }

    /// Adds up `scan`, with first plays measured against `firstPlays`, in `calendar`'s time
    /// zone and weeks. Names are left empty for `name(_:)` to fill.
    init(_ scan: PeriodScan, firstPlays: FirstPlays, calendar: Calendar) {
        span = scan.span
        paths = scan.paths
        libraryTracks = scan.libraryTracks
        undatedPlays = scan.undatedPlays
        earliestPlay = firstPlays.earliest
        addTotals(scan.paths)
        for ranking in Ranking.allCases {
            top[ranking] = Dictionary(
                uniqueKeysWithValues: List.allCases.map {
                    ($0, Self.rank($0, scan.paths, by: ranking))
                })
        }
        (firstAlbums, firstAlbumCount) = Self.firstPlayed(firstPlays.albums, \.albumID, scan)
        (firstArtists, firstArtistCount) = Self.firstPlayed(firstPlays.artists, \.artistID, scan)
        addTimes(scan, calendar: calendar)
    }

    private mutating func addTotals(_ paths: [PeriodScan.Path]) {
        var artistIDs = Set<Int64>()
        var albumIDs = Set<Int64>()
        var codecPlays: [String: Int] = [:]
        var groupPlays: [RateGroup: Int] = [:]
        for path in paths {
            plays += path.plays
            seconds += Double(path.plays) * (path.seconds ?? 0)
            if path.inLibrary {
                playedLibraryTracks += 1
                if let artist = path.artistID { artistIDs.insert(artist) }
                if let album = path.albumID { albumIDs.insert(album) }
            } else {
                missingPlays += path.plays
            }
            guard let codec = path.codec else { continue }
            codecPlays[codec, default: 0] += path.plays
            if let rate = path.sampleRateHz {
                groupPlays[.of(codec: codec, sampleRateHz: rate), default: 0] += path.plays
            }
        }
        tracks = paths.count
        artists = artistIDs.count
        albums = albumIDs.count
        codecs = codecPlays.map { Share(name: $0.key.uppercased(), plays: $0.value) }
            .sorted { $0.plays != $1.plays ? $0.plays > $1.plays : $0.name < $1.name }
        rateGroups = RateGroup.allCases.compactMap { group in
            groupPlays[group].map { Share(name: group.title, plays: $0) }
        }
    }

    /// The `listLength` entries of `list` with the most plays or hours, ties broken by the
    /// other and then by ID. Tracks are paths, a missing one a row of its own; the other lists
    /// add every path no longer in the library into one row with no ID.
    private static func rank(_ list: List, _ paths: [PeriodScan.Path], by ranking: Ranking)
        -> [Entry]
    {
        var entries: [Int64?: Entry] = [:]
        for path in paths {
            let key: Int64?
            switch list {
            case .tracks: key = path.id
            case _ where !path.inLibrary: key = nil
            case .artists:
                guard let id = path.artistID else { continue }
                key = id
            case .albums:
                guard let id = path.albumID else { continue }
                key = id
            case .genres:
                guard let id = path.genreID else { continue }
                key = id
            }
            entries[key, default: Entry(id: key, inLibrary: path.inLibrary)].plays += path.plays
            entries[key]?.seconds += Double(path.plays) * (path.seconds ?? 0)
        }
        let ordered = entries.values.sorted { left, right in
            switch ranking {
            case .plays where left.plays != right.plays: return left.plays > right.plays
            case .hours where left.seconds != right.seconds: return left.seconds > right.seconds
            case _ where left.plays != right.plays: return left.plays > right.plays
            case _ where left.seconds != right.seconds: return left.seconds > right.seconds
            default: return (left.id ?? .max) < (right.id ?? .max)
            }
        }
        return Array(ordered.prefix(listLength))
    }

    /// The albums or artists (by `key`) played in the scan's period whose first play in `first`
    /// is in it, earliest first, `listLength` at most, with their plays in the period, and how
    /// many there are.
    private static func firstPlayed(
        _ first: [Int64: Int64], _ key: KeyPath<PeriodScan.Path, Int64?>, _ scan: PeriodScan
    ) -> ([Entry], Int) {
        var entries: [Int64: Entry] = [:]
        for path in scan.paths where path.inLibrary {
            guard let id = path[keyPath: key], let when = first[id],
                scan.span?.contains(when) ?? true
            else { continue }
            entries[id, default: Entry(id: id, inLibrary: true, firstPlayed: when)].plays +=
                path.plays
            entries[id]?.seconds += Double(path.plays) * (path.seconds ?? 0)
        }
        let ordered = entries.values.sorted {
            ($0.firstPlayed ?? 0, $0.id ?? 0) < ($1.firstPlayed ?? 0, $1.id ?? 0)
        }
        return (Array(ordered.prefix(listLength)), entries.count)
    }

    // MARK: Time

    /// Adds the buckets to the bars, the months, the busiest day and the weekday × hour grid.
    /// The bars cover the period, or for All Time the days from the first play to the last.
    private mutating func addTimes(_ scan: PeriodScan, calendar: Calendar) {
        let range: PlaySpan
        if let span = scan.span {
            range = span
        } else if let first = scan.buckets.first, let last = scan.buckets.last {
            range = PlaySpan(start: first.start, end: last.start + scan.bucketSeconds)
        } else {
            return
        }
        barUnit = .fitting(days: (range.end - range.start) / 86_400)
        bars = Self.bars(barUnit, over: range, calendar: calendar, scan.buckets)
        months = barUnit == .month ? bars : Self.bars(.month, over: range, calendar: calendar, scan.buckets)
        busiestMonth = Self.busiest(months)
        var clock = LocalClock(zone: calendar.timeZone)
        var days: [Int64: Int] = [:]
        for bucket in scan.buckets {
            let local = bucket.start + clock.offset(at: bucket.start)
            let day = floorDivision(local, 86_400)
            let hour = Int(floorModulo(local, 86_400) / 3600)
            let weekday = Int(floorModulo(day + 4, 7))
            weekdayHours[weekday][hour] += bucket.plays
            days[day, default: 0] += bucket.plays
        }
        // The most plays, the earliest day among equals.
        if let (day, plays) = days.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }),
            let interval = calendar.dateInterval(of: .day, for: clock.noon(ofDay: day))
        {
            busiestDay = Bar(span: PlaySpan(interval), plays: plays)
        }
    }

    /// The calendar's `unit`s over `range`, cut to it, each with its buckets' plays.
    private static func bars(
        _ unit: BarUnit, over range: PlaySpan, calendar: Calendar, _ buckets: [PeriodScan.Bucket]
    ) -> [Bar] {
        var bars: [Bar] = []
        var date = Date(timeIntervalSince1970: TimeInterval(range.start))
        let end = Date(timeIntervalSince1970: TimeInterval(range.end))
        while date < end, let interval = calendar.dateInterval(of: unit.component, for: date) {
            let span = PlaySpan(interval)
            bars.append(
                Bar(
                    span: PlaySpan(start: max(span.start, range.start), end: min(span.end, range.end)),
                    plays: 0))
            date = interval.end
        }
        var place = 0
        for bucket in buckets {
            while place < bars.count, bars[place].span.end <= bucket.start { place += 1 }
            guard place < bars.count else { break }
            if bars[place].span.contains(bucket.start) { bars[place].plays += bucket.plays }
        }
        return bars
    }

    /// The bar with the most plays, the earliest among equals; nil when none has any.
    private static func busiest(_ bars: [Bar]) -> Bar? {
        bars.reduce(nil) { best, bar in
            bar.plays > (best?.plays ?? 0) ? bar : best
        }
    }

    // MARK: Names

    /// The IDs whose names `name(_:)` needs, by the list they're named as: the first albums
    /// and artists are named as the top lists' are.
    var namedIDs: [List: Set<Int64>] {
        var ids: [List: Set<Int64>] = [:]
        for lists in top.values {
            for (list, entries) in lists { ids[list, default: []].formUnion(entries.compactMap(\.id)) }
        }
        ids[.albums, default: []].formUnion(firstAlbums.compactMap(\.id))
        ids[.artists, default: []].formUnion(firstArtists.compactMap(\.id))
        return ids
    }

    /// Fills each entry's name and detail from `names`. The row of paths no longer in the
    /// library is named for that; a missing track keeps its title and says so in its detail.
    mutating func name(_ names: [List: [Int64: StatsName]]) {
        func named(_ entry: Entry, as list: List) -> Entry {
            var entry = entry
            guard let id = entry.id else {
                entry.name = missingText
                return entry
            }
            let name = names[list]?[id]
            entry.name = name?.name ?? ""
            entry.detail = entry.inLibrary ? name?.detail : missingText
            return entry
        }
        for (ranking, lists) in top {
            for (list, entries) in lists {
                top[ranking]?[list] = entries.map { named($0, as: list) }
            }
        }
        firstAlbums = firstAlbums.map { named($0, as: .albums) }
        firstArtists = firstArtists.map { named($0, as: .artists) }
    }

    // MARK: Tracks

    /// The tracks still in the library that `entries` of `list` were played through in the
    /// period, in the entries' order and then by plays: what Save as Playlist saves.
    public func trackIDs(of entries: [Entry], in list: List) -> [Int64] {
        let order = Dictionary(
            entries.enumerated().compactMap { place, entry in entry.id.map { ($0, place) } },
            uniquingKeysWith: { first, _ in first })
        let key: (PeriodScan.Path) -> Int64? =
            switch list {
            case .artists: { $0.artistID }
            case .albums: { $0.albumID }
            case .genres: { $0.genreID }
            case .tracks: { $0.id }
            }
        return paths.filter(\.inLibrary)
            .compactMap { path in key(path).flatMap { order[$0] }.map { (path, $0) } }
            .sorted { ($0.1, -$0.0.plays, $0.0.id) < ($1.1, -$1.0.plays, $1.0.id) }
            .map(\.0.id)
    }
}

/// What a top list shows for an ID: its name, and the album's or track's artist.
struct StatsName: Equatable, Sendable {
    var name: String
    var detail: String?
}

/// A time zone's offset from UTC at each of a run of times in increasing order, looked up
/// again only past the zone's next change.
struct LocalClock {
    let zone: TimeZone
    private var offset: Int64 = 0
    private var from = Int64.max
    private var until = Int64.min

    init(zone: TimeZone) { self.zone = zone }

    /// Seconds to add to `seconds` since 1970 for the local time then.
    mutating func offset(at seconds: Int64) -> Int64 {
        if seconds < from || seconds >= until {
            let date = Date(timeIntervalSince1970: TimeInterval(seconds))
            offset = Int64(zone.secondsFromGMT(for: date))
            from = seconds
            until =
                zone.nextDaylightSavingTimeTransition(after: date).map {
                    Int64($0.timeIntervalSince1970.rounded(.down))
                } ?? .max
        }
        return offset
    }

    /// Local noon of `day`, counted in local days from 1 January 1970: a time that is on that
    /// day whatever the day's length.
    func noon(ofDay day: Int64) -> Date {
        let local = day * 86_400 + 43_200
        let guess = Date(timeIntervalSince1970: TimeInterval(local))
        return Date(timeIntervalSince1970: TimeInterval(local - Int64(zone.secondsFromGMT(for: guess))))
    }
}

/// `value / divisor` rounded toward minus infinity, for times before 1970 as after.
func floorDivision(_ value: Int64, _ divisor: Int64) -> Int64 {
    let quotient = value / divisor
    return value % divisor < 0 ? quotient - 1 : quotient
}

/// What's left after `floorDivision`, from 0 to `divisor` - 1.
func floorModulo(_ value: Int64, _ divisor: Int64) -> Int64 {
    let remainder = value % divisor
    return remainder < 0 ? remainder + divisor : remainder
}
