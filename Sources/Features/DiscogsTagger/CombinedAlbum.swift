import DisplayText
import Library

/// Albums the library holds apart joined into one for the tagger, as Combine Albums for
/// Tagging asks (ADR 0179): one disc set split across albums, or an album and its reissue's
/// extra tracks.
struct CombinedAlbum {
    /// The albums joined, in the order their files are.
    var sources: [DiscogsAlbum]
    /// The one album the matcher and the writer see.
    var album: DiscogsAlbum

    /// `albums` joined: in order of their first disc, a file without a disc number on disc 1,
    /// then by title, each album's files in its own disc and track order, so a set split by
    /// disc reads in disc order and two albums of the same discs aren't interleaved. The
    /// search takes the first album's title, artist and details, else the first that has a
    /// detail. Its id is the first's negated, which no library album has, so what the session
    /// keeps for an album isn't mixed with what it keeps for the combination.
    init(_ albums: [DiscogsAlbum]) {
        precondition(!albums.isEmpty, "combining no albums")
        sources = albums.sorted { a, b in
            let (discA, discB) = (Self.firstDisc(a), Self.firstDisc(b))
            if discA != discB { return discA < discB }
            let title = a.title.localizedStandardCompare(b.title)
            return title != .orderedSame ? title == .orderedAscending : a.id < b.id
        }
        let first = sources[0]
        album = DiscogsAlbum(
            id: -first.id, title: first.title, artist: first.artist,
            label: sources.lazy.compactMap(\.label).first,
            catalogNumber: sources.lazy.compactMap(\.catalogNumber).first,
            barcode: sources.lazy.compactMap(\.barcode).first,
            date: sources.lazy.compactMap(\.date).first,
            media: sources.lazy.compactMap(\.media).first,
            country: sources.lazy.compactMap(\.country).first,
            tracks: sources.flatMap(\.tracks))
    }

    private static func firstDisc(_ album: DiscogsAlbum) -> Int {
        album.tracks.map { $0.discNumber ?? 1 }.min() ?? 1
    }

    /// Whether the albums' titles differ, so the files need one written to be one album.
    var titlesDiffer: Bool { Set(sources.map(\.title)).count > 1 }
    /// Whether their artists differ, as the library tells albums apart by them too.
    var artistsDiffer: Bool { Set(sources.map(\.artist)).count > 1 }

    /// "Persuader – 1983 + Persuader – 1983 [Expanded Reissue]", the album list's name of it.
    static func title(_ sources: [DiscogsAlbum]) -> String {
        sources.map(albumTitle).joined(separator: " + ")
    }

    /// "Combined from 2 albums: Persuader – 1983 (10 files) · Persuader – 1983 [Expanded
    /// Reissue] (14 files)", with `separator` between the albums.
    static func text(_ sources: [DiscogsAlbum], separator: String = " · ") -> String {
        // Always two or more.
        "Combined from \(DisplayText.number(sources.count)) albums: "
            + sources.map { "\(albumTitle($0)) (\(DisplayText.files($0.tracks.count)))" }
            .joined(separator: separator)
    }
}
