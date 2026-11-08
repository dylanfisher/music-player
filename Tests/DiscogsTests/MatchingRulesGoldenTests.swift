import CommonCrypto
import Foundation
import Testing

@testable import Discogs

// music-recommender's golden cases for its copy of the matching rules, run against the
// player's (ADR 0140). Both repos commit `rank-golden.json` byte for byte; a change on one side
// fails the SHA-256 check here until the ADR and the file change on both.

/// The golden file's SHA-256, as ADR 0140 and music-recommender's ADR 0010 record it.
private let goldenSHA256 = "c9f9134c5460472361fbd2005fbee149d3630832caf1f4706c57ce5eaaddf2d2"

private struct Golden: Decodable {
    struct Thresholds: Decodable {
        var sameTitle: Double
        var containedTitle: Double
        var containedLetters: Int
        var pairedTitle: Double
        var likelyTracklist: Double
        var durationSeconds: Double
        var durationFraction: Double
        var durationWeight: Double
    }

    struct Fold: Decodable {
        var text: String
        var title: Bool
        var key: String
    }

    struct Similarity: Decodable {
        var a: String
        var b: String
        var similarity: Double
    }

    struct Score: Decodable {
        struct Line: Decodable {
            var title: String
            var seconds: Double?
        }

        var name: String
        var files: [Line]
        var tracks: [Line]
        var mapping: [Int?]
        var sameCount: Bool
        var titlesInOrder: Bool
        var tracklist: Double
        var durationsCompared: Int
        var durationsAgreeing: Int
    }

    var thresholds: Thresholds
    var editionWords: String
    var table: [[String]]
    var fold: [Fold]
    var similarity: [Similarity]
    var score: [Score]
}

private let goldenData = Result { () throws -> Data in
    let url = try #require(
        Bundle.module.url(forResource: "Fixtures/rank-golden", withExtension: "json"))
    return try Data(contentsOf: url)
}

private let golden = Result { () throws -> Golden in
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(Golden.self, from: goldenData.get())
}

@Test func theGoldenFileIsTheOneBothReposRecord() throws {
    let data = try goldenData.get()
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest) }
    #expect(digest.map { String(format: "%02x", $0) }.joined() == goldenSHA256)
}

@Test func theThresholdsTableAndEditionWordsAreTheGoldenOnes() throws {
    let golden = try golden.get()
    let thresholds = golden.thresholds
    #expect(thresholds.sameTitle == MatchThreshold.sameTitle)
    #expect(thresholds.containedTitle == MatchThreshold.containedTitle)
    #expect(thresholds.containedLetters == MatchThreshold.containedLetters)
    #expect(thresholds.pairedTitle == MatchThreshold.pairedTitle)
    #expect(thresholds.likelyTracklist == MatchThreshold.likelyTracklist)
    #expect(thresholds.durationSeconds == MatchThreshold.durationSeconds)
    #expect(thresholds.durationFraction == MatchThreshold.durationFraction)
    #expect(thresholds.durationWeight == MatchThreshold.durationWeight)
    #expect(golden.editionWords == CatalogKey.editionWordList)
    #expect(golden.table == LatinFold.table.map { [$0.base, $0.letters] })
}

@Test func titlesFoldAsTheGoldenCasesSay() throws {
    for fold in try golden.get().fold {
        #expect(
            CatalogKey.matchKey(fold.text, title: fold.title) == fold.key,
            "\(fold.text), title \(fold.title)")
    }
}

@Test func titlesAreAsAlikeAsTheGoldenCasesSay() throws {
    for pair in try golden.get().similarity {
        let similarity = TitleSimilarity([pair.a]).similarities(to: pair.b)[0]
        #expect(abs(similarity - pair.similarity) < 1e-12, "\(pair.a) and \(pair.b)")
    }
}

@Test func tracklistsScoreAsTheGoldenCasesSay() throws {
    for golden in try golden.get().score {
        // The player always has a file's length; the service leaves one it doesn't know out of
        // the duration counts. Every golden case pairs such a file only with a track of no
        // length, or with none, so 0 stands in and counts the same.
        for (file, track) in zip(golden.files, golden.mapping) where file.seconds == nil {
            #expect(track.map { golden.tracks[$0].seconds == nil } ?? true, "\(golden.name)")
        }
        let tracks = golden.tracks.map {
            CatalogTrack(
                kind: .track, position: nil, title: $0.title,
                durationSeconds: $0.seconds.map { Int($0) })
        }
        let score = ReleaseScore.score(
            tracks, releaseID: 1, seconds: golden.files.map { $0.seconds ?? 0 },
            titles: TitleSimilarity(golden.files.map(\.title)))
        #expect(score.mapping == golden.mapping, "\(golden.name)")
        #expect(score.sameCount == golden.sameCount, "\(golden.name)")
        #expect(score.titlesInOrder == golden.titlesInOrder, "\(golden.name)")
        #expect(abs(score.tracklist - golden.tracklist) < 1e-12, "\(golden.name)")
        #expect(score.durationsCompared == golden.durationsCompared, "\(golden.name)")
        #expect(score.durationsAgreeing == golden.durationsAgreeing, "\(golden.name)")
    }
}
