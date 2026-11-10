import Foundation
import Testing

@testable import Library
@testable import Metadata

private func tags(
    title: String? = "Song", artist: String? = "Artist", album: String? = "Album",
    albumArtist: String? = nil, track: Int? = 3, disc: Int? = nil, discs: Int? = nil
) -> TrackTags {
    var tags = TrackTags()
    tags.title = title
    tags.artist = artist
    tags.album = album
    tags.albumArtist = albumArtist
    tags.trackNumber = track
    tags.discNumber = disc
    tags.discTotal = discs
    return tags
}

@Test func aFileGoesUnderItsAlbumArtistAndAlbumByNumberAndTitle() {
    #expect(libraryFolderPath(for: tags(), of: "/in/x.flac") == "Artist/Album/03 Song.flac")
    #expect(
        libraryFolderPath(for: tags(albumArtist: "Various Artists"), of: "/in/x.m4a")
            == "Various Artists/Album/03 Song.m4a")
}

@Test func aDiscNumberLeadsWhenTheAlbumHasMoreThanOneDisc() {
    #expect(
        libraryFolderPath(for: tags(disc: 1, discs: 2), of: "/x.flac")
            == "Artist/Album/1-03 Song.flac")
    #expect(libraryFolderPath(for: tags(disc: 2), of: "/x.flac") == "Artist/Album/2-03 Song.flac")
    #expect(
        libraryFolderPath(for: tags(disc: 1, discs: 1), of: "/x.flac")
            == "Artist/Album/03 Song.flac")
}

@Test func missingTagsFallBackToTheFileNameAndUnknownFolders() {
    #expect(
        libraryFolderPath(
            for: tags(title: nil, artist: nil, album: nil, track: nil), of: "/in/My Rip.mp3")
            == "Unknown Artist/Unknown Album/My Rip.mp3")
    #expect(
        libraryFolderPath(for: tags(title: "  ", artist: "", album: "..."), of: "/in/b.flac")
            == "Unknown Artist/Unknown Album/03 b.flac")
}

@Test func namesLoseWhatAVolumeOrAShareRefuses() {
    #expect(
        libraryFolderPath(
            for: tags(title: "What?/Why: \"Now\"", artist: "AC/DC", album: ".hidden "),
            of: "/x.flac") == "AC_DC/hidden/03 What__Why - _Now_.flac")
    #expect(safeName("a\u{0}b\u{1F}c\u{7F}", maxBytes: 255) == "abc")
    #expect(safeName("  .. Intro. ", maxBytes: 255) == "Intro")
}

@Test func aColonBecomesADashSoASubtitleStillReads() {
    #expect(
        libraryFolderPath(
            for: tags(title: "Intro (5:40)", album: "Éthiopiques 22: More Vintage! 1972-1974"),
            of: "/x.flac")
            == "Artist/Éthiopiques 22 - More Vintage! 1972-1974/03 Intro (5-40).flac")
    #expect(safeName("Live :  Paris", maxBytes: 255) == "Live - Paris")
}

@Test func aLongNameIsCutToFitWithItsExtension() {
    let name =
        (libraryFolderPath(
            for: tags(title: String(repeating: "é", count: 300)), of: "/x.flac") as NSString)
        .lastPathComponent
    #expect(name.utf8.count <= 255)
    #expect(name.hasSuffix("é.flac"))
    #expect(name.hasPrefix("03 é"))
}
