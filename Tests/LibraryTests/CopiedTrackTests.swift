import Testing

@testable import Library

@Test func copiedTracksAreOneArtistAndTitleLineEach() {
    let tracks = [
        CopiedTrack(path: "/m/a.flac", artist: "Aphex Twin", title: "Windowlicker"),
        CopiedTrack(path: "/m/b.flac", artist: nil, title: "Untitled"),
        CopiedTrack(path: "/m/c.flac", artist: "", title: "Blank"),
    ]
    #expect(CopiedTrack.text(tracks) == "Aphex Twin – Windowlicker\nUntitled\nBlank")
    #expect(CopiedTrack.text([]) == "")
}
