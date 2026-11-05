import Settings

/// What `music-player stats --json` prints: the report's figures under plain keys, the top
/// lists by ranking and then list. Times are seconds since 1970; durations are seconds.
extension StatsReport: Encodable {
    private enum CodingKeys: String, CodingKey {
        case span, plays, seconds, tracks, artists, albums, libraryTracks, playedLibraryTracks
        case missingPlays, undatedPlays, top, barUnit, bars, months, weekdayHours, busiestDay
        case busiestMonth, firstAlbums, firstArtists, firstAlbumCount, firstArtistCount, codecs
        case rateGroups, earliestPlay
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(span, forKey: .span)
        try container.encode(plays, forKey: .plays)
        try container.encode(seconds.rounded(), forKey: .seconds)
        try container.encode(tracks, forKey: .tracks)
        try container.encode(artists, forKey: .artists)
        try container.encode(albums, forKey: .albums)
        try container.encode(libraryTracks, forKey: .libraryTracks)
        try container.encode(playedLibraryTracks, forKey: .playedLibraryTracks)
        try container.encode(missingPlays, forKey: .missingPlays)
        try container.encode(undatedPlays, forKey: .undatedPlays)
        // Keyed by the enums' names: a dictionary with enum keys would encode as an array.
        let lists = Dictionary(
            uniqueKeysWithValues: top.map { ranking, lists in
                (ranking.rawValue, Dictionary(uniqueKeysWithValues: lists.map { ($0.key.rawValue, $0.value) }))
            })
        try container.encode(lists, forKey: .top)
        try container.encode(barUnit, forKey: .barUnit)
        try container.encode(bars, forKey: .bars)
        try container.encode(months, forKey: .months)
        try container.encode(weekdayHours, forKey: .weekdayHours)
        try container.encodeIfPresent(busiestDay, forKey: .busiestDay)
        try container.encodeIfPresent(busiestMonth, forKey: .busiestMonth)
        try container.encode(firstAlbums, forKey: .firstAlbums)
        try container.encode(firstArtists, forKey: .firstArtists)
        try container.encode(firstAlbumCount, forKey: .firstAlbumCount)
        try container.encode(firstArtistCount, forKey: .firstArtistCount)
        try container.encode(codecs, forKey: .codecs)
        try container.encode(rateGroups, forKey: .rateGroups)
        try container.encodeIfPresent(earliestPlay, forKey: .earliestPlay)
    }
}
