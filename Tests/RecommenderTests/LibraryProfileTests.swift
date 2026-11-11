import Foundation
import Testing

@testable import Recommender

@Test func aProfileEncodesAsTheServiceReadsIt() throws {
    let profile = LibraryProfile(albums: [
        LibraryProfile.Album(
            artist: "Made-Up Artist", title: "Made-Up Album", durations: [245, 750],
            catalogNumbers: ["MU 001"], barcodes: ["012345678905"], discogsReleaseID: 4242,
            plays: 31, loved: 1),
        LibraryProfile.Album(
            artist: "Other", title: "Untagged", durations: [], catalogNumbers: [], barcodes: [],
            discogsReleaseID: nil, plays: 0, loved: 0),
    ])
    #expect(
        String(decoding: profile.json(), as: UTF8.self)
            == #"{"albums":[{"artist":"Made-Up Artist","barcodes":["012345678905"],"#
            + #""catalog_numbers":["MU 001"],"discogs_release_id":4242,"durations":[245,750],"#
            + #""loved":1,"plays":31,"title":"Made-Up Album","track_count":2},"#
            + #"{"artist":"Other","barcodes":[],"catalog_numbers":[],"discogs_release_id":null,"#
            + #""durations":[],"loved":0,"plays":0,"title":"Untagged","track_count":0}]}"#)
}
