import Foundation
import Library
import Testing

@testable import Discogs

/// The tie-break's steps and helpers on releases that fit an album equally (ADR 0131), each test
/// a boundary a mutant of `TieBreak.swift` crossed unseen (ADR 0027).

/// A CD release with what the tie-break reads; `numbers` are its labels' catalog numbers in order.
private func release(
    _ id: Int, numbers: [String?] = [], barcodes: [String] = [], released: String? = nil,
    country: String? = nil, format: String = "CD", descriptions: [String] = []
) -> CatalogRelease {
    CatalogRelease(
        id: id, title: "Stockholm",
        labels: numbers.map { CatalogRelease.Label(name: "Svek", catalogNumber: $0) },
        formats: [CatalogRelease.Format(name: format, descriptions: descriptions)],
        country: country,
        released: released, barcodes: barcodes)
}

private func album(
    catalogNumber: String? = nil, barcode: String? = nil, date: String? = nil,
    media: String? = nil, country: String? = nil
) -> DiscogsAlbum {
    DiscogsAlbum(
        id: 1, title: "Stockholm", artist: "Persuader", catalogNumber: catalogNumber,
        barcode: barcode, date: date, media: media, country: country, tracks: [])
}

/// The release the tie-break picks among `releases`, all fitting equally, and whether it's a tie.
private func pick(_ album: DiscogsAlbum, _ releases: [CatalogRelease]) -> (id: Int, tied: Bool) {
    let scores = releases.map {
        ReleaseScore(
            releaseID: $0.id, tracks: [], mapping: [], sameCount: true, tracklist: 1,
            titlesInOrder: true, durationsCompared: 0, durationsAgreeing: 0)
    }
    let (score, tied) = tieBreak(
        scores, releases: Dictionary(uniqueKeysWithValues: releases.map { ($0.id, $0) }),
        album: album)
    return (score.releaseID, tied)
}

@Test func anEmptyBarcodeMatchesNoReleaseWithAnEmptyOne() {
    let result = pick(album(barcode: ""), [release(1), release(2, barcodes: [""])])
    #expect(result.tied)
}

@Test func aBarcodeSpelledAsTaggedBeatsOneThatOnlyFoldsTheSame() {
    let result = pick(
        album(barcode: "5 012345 678900"),
        [release(1, barcodes: ["5012345678900"]), release(2, barcodes: ["5 012345 678900"])])
    #expect(result.id == 2)
    #expect(!result.tied)
}

@Test func aBarcodeThatOnlyFoldsTheSameBeatsNone() {
    let result = pick(
        album(barcode: "5 012345 678900"),
        [release(1, barcodes: ["4 000000 000000"]), release(2, barcodes: ["5012345678900"])])
    #expect(result.id == 2)
    #expect(!result.tied)
}

@Test func theMediaAsTaggedBeatsAFormatDiscogsHasSinceDescribedMore() {
    let result = pick(
        album(media: "Vinyl (LP)"),
        [
            release(1, format: "Vinyl", descriptions: ["LP", "Stereo"]),
            release(2, format: "Vinyl", descriptions: ["LP"]),
        ])
    #expect(result.id == 2)
    #expect(!result.tied)
}

@Test func aFormatThatFitsTheMediaBeatsOneThatDoesnt() {
    let result = pick(
        album(media: "Vinyl (LP)"),
        [release(1), release(2, format: "Vinyl", descriptions: ["LP", "Stereo"])])
    #expect(result.id == 2)
    #expect(!result.tied)
}

@Test func theDateAsTaggedBeatsOneThatOnlyFitsAndOneThatFitsBeatsNone() {
    let exact = pick(
        album(date: "2001-05-15"),
        [release(1, released: "2001-05"), release(2, released: "2001-05-15")])
    #expect(exact.id == 2)
    #expect(!exact.tied)
    let fitting = pick(album(date: "2001"), [release(1), release(2, released: "2001-03-00")])
    #expect(fitting.id == 2)
    #expect(!fitting.tied)
}

@Test func aCountryThatFitsBeatsNone() {
    let result = pick(album(country: "UK"), [release(1), release(2, country: "UK & Europe")])
    #expect(result.id == 2)
    #expect(!result.tied)
}

@Test func theCountryMostOfATieShareIsChosenOverAReleaseWithNone() {
    let result = pick(album(), [release(1), release(2, country: "UK"), release(3, country: "UK")])
    #expect(result.id == 2)
    #expect(result.tied)
}

@Test func aNumberOnAnotherLabelBeatsNoneThatFits() {
    let result = pick(
        album(catalogNumber: "SK 032"),
        [release(1, numbers: ["XX 1"]), release(2, numbers: ["YY 2", "SK 032"])])
    #expect(result.id == 2)
    #expect(!result.tied)
}

@Test func aNumberOnTheFirstLabelBeatsOneOnAnother() {
    let result = pick(
        album(catalogNumber: "SK 032"),
        [release(1, numbers: ["XX 1", "SK 032"]), release(2, numbers: ["SK 032"])])
    #expect(result.id == 2)
    #expect(!result.tied)
}

@Test func aReleaseWithNoLabelWeighsNoMoreThanOneWithAnotherNumber() {
    let result = pick(album(catalogNumber: "SK 032"), [release(1), release(2, numbers: ["ZZ 9"])])
    #expect(result.tied)
}

@Test func theBarcodeAndTheNumberTogetherBeatEitherAlone() {
    let releases = [
        release(1, numbers: ["SK 032"]), release(2, barcodes: ["5012345678900"]),
        release(3, numbers: ["SK 032"], barcodes: ["5012345678900"]),
    ]
    let result = pick(album(catalogNumber: "SK 032", barcode: "5012345678900"), releases)
    #expect(result.id == 3)
    #expect(!result.tied)
}

@Test func aYearAloneOnlyFitsAndTellsNoPressingsApart() {
    let result = pick(
        album(date: "2001"), [release(1, released: "2001-05-15"), release(2, released: "2001")])
    #expect(result.tied)
}

@Test func anExactCountryBeatsARegionThatFitsItEitherWay() {
    let inUK = pick(
        album(country: "UK"), [release(1, country: "UK & Europe"), release(2, country: "UK")])
    #expect(inUK.id == 2)
    #expect(!inUK.tied)
    let inRegion = pick(
        album(country: "UK & Europe"),
        [release(1, country: "UK"), release(2, country: "UK & Europe")])
    #expect(inRegion.id == 2)
    #expect(!inRegion.tied)
}

@Test func noCountryInTheTagsLeavesTheTie() {
    let result = pick(album(), [release(1, country: "UK"), release(2)])
    #expect(result.tied)
}

@Test func aPressingIsTheSameMonthAtLeast() {
    let sameMonth = (release(1, released: "2001-05-00"), release(2, released: "2001-05-15"))
    #expect(samePressing(sameMonth.0, sameMonth.1))
    // A year alone, or a month Discogs left as 00, names no month.
    #expect(!samePressing(release(1, released: "2001-00-00"), release(2, released: "2001-00-00")))
    #expect(!samePressing(release(1, released: "2001"), release(2, released: "2001")))
    #expect(!samePressing(release(1, released: "2001-05"), release(2, released: "2001-06")))
    #expect(!samePressing(release(1, released: "2001-05-15"), release(2)))
    #expect(
        !samePressing(
            release(1, released: "2001-05-15"), release(2, released: "2001-05-15", format: "Vinyl"))
    )
    #expect(
        samePressing(
            release(1, numbers: ["SK 032"], released: "1999"),
            release(2, numbers: ["sk-032"], released: "2004")))
}

@Test func datesFitAsFarAsBothSay() {
    #expect(datesFit("2001", "2001"))
    #expect(datesFit("2001-00-00", "2001-10-15"))
    #expect(datesFit("2001-05-00", "2001-05-15"))
    #expect(datesFit("2001-05-15", "2001"))
    #expect(!datesFit("2001-05", "2001-06"))
    #expect(!datesFit("abc", "abc"))
    #expect(!datesFit("abc", "abcd"))
    #expect(!datesFit("abcd", "abc"))
}
