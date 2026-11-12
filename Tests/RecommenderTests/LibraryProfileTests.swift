import Foundation
import Testing

@testable import Recommender

@Test func aProfileEncodesAsTheServiceReadsIt() throws {
    let profile = LibraryProfile(albums: [
        LibraryProfile.Album(
            key: "a812", artist: "Made-Up Artist", title: "Made-Up Album",
            durations: [245, 750], catalogNumbers: ["MU 001"], barcodes: ["012345678905"],
            discogsReleaseID: 4242, plays: 31, loved: 1, lastPlayed: 1_793_000_000, skips: 2),
        LibraryProfile.Album(
            key: "a9", artist: "Other", title: "Untagged", durations: [], catalogNumbers: [],
            barcodes: [], discogsReleaseID: nil, plays: 0, loved: 0, lastPlayed: nil, skips: 0),
    ])
    #expect(
        String(decoding: profile.json(), as: UTF8.self)
            == #"{"albums":[{"artist":"Made-Up Artist","barcodes":["012345678905"],"#
            + #""catalog_numbers":["MU 001"],"discogs_release_id":4242,"durations":[245,750],"#
            + #""key":"a812","last_played":1793000000,"loved":1,"plays":31,"skips":2,"#
            + #""title":"Made-Up Album","track_count":2},"#
            + #"{"artist":"Other","barcodes":[],"catalog_numbers":[],"discogs_release_id":null,"#
            + #""durations":[],"key":"a9","last_played":null,"loved":0,"plays":0,"skips":0,"#
            + #""title":"Untagged","track_count":0}]}"#)
}
