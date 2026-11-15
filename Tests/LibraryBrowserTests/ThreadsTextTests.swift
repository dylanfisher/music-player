import Foundation
import Testing

@testable import LibraryBrowser
@testable import Recommender

@Test func theCardListsAllThenEachThreadWithTheAlbumsTheTableLists() {
    let reply = albumThreads(
        "a2", ["a7", "a3", "a5"], threads: [("Engineer: Dee", ["a5", "a7"]), ("Label", ["a3"])])
    let rows = threadsRows(reply.shown(by: .defaults, now: Date()), listed: ["ka7", "ka5"])
    #expect(rows.map(\.name) == ["All", "Engineer: Dee", "Label"])
    #expect(rows.map(\.value) == ["2", "2", "0"])
    #expect(rows.map(\.dimmed) == [false, false, true], "a thread of no album here")
    #expect(rows[1].fraction == 1)
}

@Test func theCardCountsOnlyTheAlbumsTheFiltersPass() {
    var reply = albumThreads(
        "a2", ["a7", "a3", "a5"], threads: [("Engineer: Dee", ["a5", "a7"]), ("Label", ["a3"])])
    reply.albums[0].plays = 2
    var filter = ThreadsFilter.defaults
    filter.played = .neverPlayed
    let rows = threadsRows(
        reply.shown(by: filter, now: Date()), listed: ["ka7", "ka3", "ka5"])
    #expect(rows.map(\.value) == ["2", "1", "1"])
}

@Test func theKindsTitleNamesTheKindsHidden() {
    #expect(threadsKindsTitle(hidden: []) == "All Kinds")
    #expect(threadsKindsTitle(hidden: [.styles]) == "Kinds: no Styles")
    #expect(threadsKindsTitle(hidden: [.styles, .label]) == "Kinds: no Labels or Styles")
    #expect(
        threadsKindsTitle(hidden: [.styles, .credit, .related])
            == "Kinds: no Credits, Related Artists or Styles")
}

@Test func theSeedsTitleHasItsArtistAndYear() {
    var seed = rediscovered("a2")
    #expect(threadsSeedTitle(seed) == "Album a2 – Made-Up Artist")
    seed.year = 1997
    #expect(threadsSeedTitle(seed) == "Album a2 – Made-Up Artist, 1997")
}

@Test func theThreadsRefusalsAreSaidInWords() {
    for code in [ServiceRefusal.Code.noSeed, .untagged, .noCatalog, .noProfile] {
        let text = threadsProblemText(.refused(ServiceRefusal(code: code, message: "m")))
        #expect(!text.contains(code.rawValue), "\(code): \(text)")
    }
    #expect(threadsProblemText(.unknownAlbums(2)).hasPrefix("2 albums of the threads"))
}
