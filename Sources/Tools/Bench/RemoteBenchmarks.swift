import Artwork
import Foundation
import Library
import LocalNetwork
import Remote
import Settings

/// The web remote's reads on the server, from the request's path to its JSON, over the fixture
/// library (phase 10b): the Artists list, a search per keystroke and an album's tracks.
let remoteBenchmarks = [
    Benchmark(
        name: "remote: the whole Artists list as the page reads it (p95)",
        budget: Budget(appleSilicon: 30, oldMac: 150, unit: .milliseconds)
    ) {
        let library = try remoteLibrary()
        let samples = try millisecondSamples(
            (0..<20).map { _ in { try remoteRead(library, RemoteRoute.artists, nil) } })
        return Measured(value: p95(samples), notes: [slowestNote(samples)])
    },
    Benchmark(
        name: "remote: a search's artists, albums and tracks per keystroke (p95)",
        budget: Budget(appleSilicon: 25, oldMac: 100, unit: .milliseconds)
    ) {
        let library = try remoteLibrary()
        let typed = try typedQueries(try scannedLibrary.get().index)
        let samples = try millisecondSamples(
            typed.map { text in
                {
                    let query =
                        "q="
                        + (text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
                    try remoteRead(library, RemoteRoute.search, query)
                }
            })
        return Measured(
            value: p95(samples), notes: ["over \(samples.count) keystrokes", slowestNote(samples)])
    },
    Benchmark(
        name: "remote: an album's tracks, the first range (p95)",
        budget: Budget(appleSilicon: 10, oldMac: 50, unit: .milliseconds)
    ) {
        let library = try remoteLibrary()
        let albums = try scannedLibrary.get().index.albums().prefix(200)
        let samples = try millisecondSamples(
            albums.map { album in
                {
                    try remoteRead(
                        library, RemoteRoute.tracks,
                        "album=\(album.id)&sort=album&offset=0&limit=200")
                }
            })
        return Measured(
            value: p95(samples), notes: ["\(samples.count) albums' tracks", slowestNote(samples)])
    },
]

/// The remote's reads on a connection of their own to the fixture library, opened before any
/// sample is taken.
private func remoteLibrary() throws -> RemoteLibrary {
    let library = RemoteLibrary(
        databaseURL: try scannedLibrary.get().databaseURL,
        thumbnails: ThumbnailStore(directory: try emptyCacheDirectory("bench-remote-art")),
        groupByAlbumArtist: false)
    try remoteRead(library, RemoteRoute.genres, nil)
    return library
}

private func remoteRead(_ library: RemoteLibrary, _ path: String, _ query: String?) throws {
    let status = try waited { await library.reply(path, query: query, ifNoneMatch: nil)?.status }
    guard status == .ok else {
        throw BenchError.expected(
            "\(path)?\(query ?? "") to answer 200: \(String(describing: status))")
    }
}
