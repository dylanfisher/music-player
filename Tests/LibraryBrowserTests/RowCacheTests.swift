import Testing

@testable import Library
@testable import LibraryBrowser

private func row(_ id: Int64) -> TrackRow {
    TrackRow(
        id: id, path: "/m/\(id).flac", title: "\(id)", artist: nil, album: nil, albumID: nil,
        albumArtist: nil, genre: nil, date: nil, trackNumber: nil, discNumber: nil, codec: "flac",
        sampleRateHz: 44100, bitsPerSample: 16, durationSeconds: 1, addedSeconds: 0, art: nil)
}

@Test func fetchesAPageAtATimeAndKeepsAtMostItsCapacity() throws {
    var fetched: [[Int64]] = []
    let cache = RowCache(pageSize: 10, capacityPages: 2) { ids in
        fetched.append(ids)
        return ids.map(row)
    }
    cache.setIDs(Array(100..<135))
    #expect(try cache.row(at: 3)?.id == 103)
    #expect(try cache.row(at: 9)?.id == 109)
    #expect(fetched == [Array(100..<110)])
    _ = try cache.row(at: 15)
    _ = try cache.row(at: 0)  // page 0 is now the most recently used
    _ = try cache.row(at: 34)  // the last, short page; page 1 goes
    #expect(fetched.last == Array(130..<135))
    _ = try cache.row(at: 1)
    #expect(fetched.count == 3)
    _ = try cache.row(at: 12)
    #expect(fetched.count == 4)
}

@Test func newIDsOrAnInvalidationDropTheCache() throws {
    var fetches = 0
    let cache = RowCache(pageSize: 4, capacityPages: 4) { ids in
        fetches += 1
        return ids.filter { $0 != 2 }.map(row)
    }
    cache.setIDs([1, 2, 3])
    #expect(try cache.row(at: 1) == nil)  // gone from the index since the IDs were loaded
    #expect(try cache.row(at: 2)?.id == 3)
    cache.invalidate()
    _ = try cache.row(at: 0)
    cache.setIDs([3, 1])
    #expect(try cache.row(at: 0)?.id == 3)
    #expect(fetches == 3)
}
