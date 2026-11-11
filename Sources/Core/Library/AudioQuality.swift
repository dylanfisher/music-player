import DisplayText
import Recommender

/// An album's or a download's audio quality, as Approve Safe Matches Automatically compares a
/// new album with the library album it replaces (ADR 0195). Unknown is nil, never a guess.
package enum AudioQuality: Equatable, Sendable, CustomStringConvertible {
    /// `format` names the codecs, "FLAC" or "ALAC/FLAC".
    case lossless(format: String, bitDepth: Int, sampleRateHz: Int)
    /// `kbps` is the average bit rate, above 0.
    case lossy(format: String, kbps: Int)

    /// Whether this is clearly higher quality than `other`: lossless over lossy; of two
    /// lossless, a bit depth and a sample rate each at least as high and one higher; of two
    /// lossy, an average bit rate at least `lossyMarginPercent` higher. Lossy is never higher
    /// than lossless, and a mixed result, such as 24/44.1 against 16/96, isn't higher.
    package func isClearlyHigher(than other: AudioQuality) -> Bool {
        switch (self, other) {
        case (.lossless(_, let bits, let rate), .lossless(_, let otherBits, let otherRate)):
            bits >= otherBits && rate >= otherRate && (bits > otherBits || rate > otherRate)
        case (.lossless, .lossy): true
        case (.lossy, .lossless): false
        case (.lossy(_, let kbps), .lossy(_, let otherKbps)):
            kbps * 100 >= otherKbps * (100 + lossyMarginPercent) && kbps > otherKbps
        }
    }

    /// "FLAC 16/44.1", "MP3 320 kbps".
    package var description: String {
        switch self {
        case .lossless(let format, let bits, let rate):
            "\(format) \(bits)/\(kilohertz(Double(rate)))"
        case .lossy(let format, let kbps): "\(format) \(kbpsText(Double(kbps)))"
        }
    }

    /// The quality of the folder `candidate` the service chose, held to what the lossy-origin
    /// check read of the staged files, `measured`: their bit depth and sample rate, the lowest
    /// of them, where it read any, over the peer's report. Nil when the peer didn't report what
    /// the comparison needs, or the files read aren't the kind of codec it reported.
    package static func staged(_ candidate: DownloadJob.Candidate?, measured: [FileMeasures])
        -> AudioQuality?
    {
        guard let candidate else { return nil }
        let format = candidate.format.rawValue.uppercased()
        switch candidate.format {
        case .flac, .alac, .wav, .ape, .wv:
            if !measured.isEmpty {
                let bits = measured.map(\.storedBits)
                guard bits.allSatisfy({ $0 != nil }), let depth = bits.compactMap({ $0 }).min(),
                    let rate = measured.map(\.sampleRateHz).min(), rate > 0
                else { return nil }
                return .lossless(format: format, bitDepth: depth, sampleRateHz: Int(rate))
            }
            guard let depth = candidate.bitDepth, let rate = candidate.sampleRateHz, rate > 0
            else { return nil }
            return .lossless(format: format, bitDepth: depth, sampleRateHz: rate)
        case .mp3, .ogg, .opus:
            guard measured.allSatisfy({ $0.storedBits == nil }),
                let kbps = candidate.bitrateKbps, kbps > 0
            else { return nil }
            return .lossy(format: format, kbps: kbps)
        }
    }
}

/// How much higher, in percent, a lossy download's average bit rate must be than a lossy
/// library album's to be clearly higher quality (ADR 0195).
let lossyMarginPercent = 10

extension LibraryIndex {
    /// The quality of the library album `album`, from its tracks' codecs, bit depths, sample
    /// rates and average bit rate. With any lossless track, its highest bit depth and highest
    /// sample rate, which a download must reach to be higher than every track; else the
    /// album's average bit rate, as `upgradeCandidates` works it out. Nil for an album with no
    /// tracks, a DSD track, or a lossless track with no bit depth.
    package func albumQuality(_ album: Int64) throws -> AudioQuality? {
        let tracks = try statement(
            """
            SELECT t.codec, t.bits_per_sample, t.sample_rate_hz, f.size_bytes,
                ifnull(t.art_byte_count, 0), t.length_frames
            FROM tracks t JOIN files f ON f.id = t.file_id WHERE t.album_id = ?
            """
        ).map(album) { row in
            let rateHz = try row.int(2)
            return (
                codec: try row.text(0), bits: row.optionalInt(1), rateHz: rateHz,
                audioBytes: try row.int(3) - (try row.int(4)),
                seconds: rateHz > 0 ? Double(try row.int(5)) / Double(rateHz) : 0
            )
        }
        guard !tracks.isEmpty,
            tracks.allSatisfy({
                losslessCodecs.contains($0.codec) || lossyCodecs.contains($0.codec)
            })
        else { return nil }
        let lossless = tracks.filter { losslessCodecs.contains($0.codec) }
        if !lossless.isEmpty {
            let depths = lossless.map(\.bits)
            guard depths.allSatisfy({ $0 != nil }), let depth = depths.compactMap({ $0 }).max(),
                let rate = lossless.map(\.rateHz).max(), rate > 0
            else { return nil }
            return .lossless(
                format: formatName(lossless.map(\.codec)), bitDepth: depth, sampleRateHz: rate)
        }
        let kbps = averageKbps(
            audioBytes: tracks.map(\.audioBytes).reduce(0, +),
            seconds: tracks.map(\.seconds).reduce(0, +))
        guard kbps > 0 else { return nil }
        return .lossy(format: formatName(tracks.map(\.codec)), kbps: kbps)
    }
}
