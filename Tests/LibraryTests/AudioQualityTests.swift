import Foundation
import Testing

@testable import Library
@testable import Metadata
@testable import Recommender

// Whether a download is clearly higher quality than the library album it replaces (ADR 0195),
// and where each side's quality comes from.

private func flac(_ bits: Int, _ rateHz: Int) -> AudioQuality {
    .lossless(format: "FLAC", bitDepth: bits, sampleRateHz: rateHz)
}

private func mp3(_ kbps: Int) -> AudioQuality { .lossy(format: "MP3", kbps: kbps) }

@Test func losslessIsClearlyHigherThanLossyAndNeverTheOtherWay() {
    #expect(flac(16, 44_100).isClearlyHigher(than: mp3(320)))
    #expect(!mp3(320).isClearlyHigher(than: flac(16, 44_100)))
    #expect(!mp3(9_999).isClearlyHigher(than: flac(16, 44_100)))
}

@Test func losslessIsHigherOnlyWhenNeitherBitDepthNorSampleRateIsLower() {
    #expect(flac(24, 44_100).isClearlyHigher(than: flac(16, 44_100)))
    #expect(flac(16, 96_000).isClearlyHigher(than: flac(16, 44_100)))
    #expect(flac(24, 96_000).isClearlyHigher(than: flac(16, 44_100)))
    #expect(!flac(16, 44_100).isClearlyHigher(than: flac(16, 44_100)), "the same")
    #expect(!flac(24, 44_100).isClearlyHigher(than: flac(16, 96_000)), "mixed")
    #expect(!flac(16, 96_000).isClearlyHigher(than: flac(24, 44_100)), "mixed")
    #expect(!flac(16, 44_100).isClearlyHigher(than: flac(24, 96_000)))
}

@Test func lossyIsHigherOnlyByAtLeastTenPercent() {
    #expect(mp3(320).isClearlyHigher(than: mp3(256)))
    #expect(mp3(220).isClearlyHigher(than: mp3(200)), "exactly 10%")
    #expect(!mp3(219).isClearlyHigher(than: mp3(200)))
    #expect(!mp3(320).isClearlyHigher(than: mp3(320)))
    #expect(!mp3(256).isClearlyHigher(than: mp3(320)))
}

@Test func aQualityReadsAsTheDownloadsWindowNamesFormats() {
    #expect(flac(16, 44_100).description == "FLAC 16/44.1")
    #expect(flac(24, 96_000).description == "FLAC 24/96")
    #expect(mp3(320).description == "MP3 320 kbps")
}

private func candidate(
    _ format: String, bits: Int? = nil, rateHz: Int? = nil, kbps: Int? = nil
) throws -> DownloadJob.Candidate {
    let json = """
        {"peer": "made-up-peer", "format": "\(format)", "bit_depth": \(bits.map(String.init) ?? "null"),
         "sample_rate": \(rateHz.map(String.init) ?? "null"), "bitrate": \(kbps.map(String.init) ?? "null"),
         "variable_bitrate": null, "file_count": 2, "bytes": 1000, "tracklist": 0}
        """
    return try JSONDecoder().decode(DownloadJob.Candidate.self, from: Data(json.utf8))
}

private func measured(bits: Int?, rateHz: Double) -> FileMeasures {
    FileMeasures(
        formatID: bits == nil ? ".mp3" : "flac", sampleRateHz: rateHz, storedBits: bits,
        channels: 2, isFloat: false, durationSeconds: 200, cutoffHz: nil,
        cutoffSteepnessDBPerKHz: nil, effectiveBits: bits, identicalChannels: false,
        peakDBFS: -1, truePeakDBTP: -1, clippedRuns: 0, dynamicRange: 10)
}

@Test func aDownloadsQualityIsWhatTheCheckReadOverWhatThePeerReported() throws {
    let reported = try candidate("flac", bits: 24, rateHz: 96_000)
    #expect(AudioQuality.staged(reported, measured: []) == flac(24, 96_000))
    // The lowest the check read, of the files it read.
    #expect(
        AudioQuality.staged(
            reported,
            measured: [measured(bits: 16, rateHz: 44_100), measured(bits: 24, rateHz: 96_000)])
            == flac(16, 44_100))
    #expect(
        AudioQuality.staged(try candidate("flac"), measured: [measured(bits: 24, rateHz: 48_000)])
            == flac(24, 48_000), "the peer reported nothing")
    #expect(AudioQuality.staged(try candidate("mp3", kbps: 320), measured: []) == mp3(320))
    #expect(
        AudioQuality.staged(
            try candidate("mp3", kbps: 320), measured: [measured(bits: nil, rateHz: 44_100)])
            == mp3(320))
}

@Test func aDownloadsQualityIsUnknownWithoutWhatTheComparisonNeeds() throws {
    #expect(AudioQuality.staged(nil, measured: []) == nil)
    #expect(AudioQuality.staged(try candidate("flac", bits: 16), measured: []) == nil)
    #expect(AudioQuality.staged(try candidate("mp3"), measured: []) == nil)
    // The files read aren't the kind of codec the peer reported.
    #expect(
        AudioQuality.staged(
            try candidate("flac", bits: 16, rateHz: 44_100),
            measured: [measured(bits: nil, rateHz: 44_100)]) == nil)
    #expect(
        AudioQuality.staged(
            try candidate("mp3", kbps: 320), measured: [measured(bits: 16, rateHz: 44_100)])
            == nil)
}

/// A track of the album `album`, `seconds` long, at `kbps` with its 10 bytes of art.
private func track(
    _ album: String, _ number: Int, codec: TrackAudio.Codec, bits: Int? = 16,
    rateHz: Int = 44_100, kbps: Int = 1_000
) -> ScannedFile {
    var crafted = Crafted(
        path: "/Volumes/music/library/A/\(album)/\(number).\(codec.rawValue)",
        title: "Song \(number)", album: album, albumArtist: "Made-Up Artist", number: number,
        rateHz: rateHz, codec: codec)
    crafted.bits = bits
    crafted.sizeBytes = kbps * 1000 / 8 * Int(crafted.seconds) + 10
    return crafted.scanned
}

@Test func aLibraryAlbumsQualityIsItsBestLosslessOrItsAverageBitRate() throws {
    let index = try craftedIndex([
        track("Lossy", 1, codec: .mp3, bits: nil, kbps: 300),
        track("Lossy", 2, codec: .mp3, bits: nil, kbps: 200),
        track("Mixed Rates", 1, codec: .flac, bits: 24, rateHz: 44_100),
        track("Mixed Rates", 2, codec: .flac, bits: 16, rateHz: 96_000),
        track("Partly Lossless", 1, codec: .mp3, bits: nil, kbps: 320),
        track("Partly Lossless", 2, codec: .alac, bits: 16),
        track("No Depth", 1, codec: .flac, bits: nil),
        track("DSD", 1, codec: .dsd, bits: 1, rateHz: 2_822_400),
    ])
    let albums = Dictionary(
        uniqueKeysWithValues: try index.discogsAlbums().map { ($0.title, $0.id) })
    let quality = { (title: String) in try index.albumQuality(try #require(albums[title])) }
    #expect(try quality("Lossy") == mp3(250))
    // The highest of each, so a download must be higher than every track.
    #expect(try quality("Mixed Rates") == flac(24, 96_000))
    #expect(
        try quality("Partly Lossless")
            == .lossless(format: "ALAC", bitDepth: 16, sampleRateHz: 44_100))
    #expect(try quality("No Depth") == nil)
    #expect(try quality("DSD") == nil)
}
