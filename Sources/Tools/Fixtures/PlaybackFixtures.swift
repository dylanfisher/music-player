import Foundation
import Log

/// `~/Library/Caches/MusicPlayer/playback-fixtures`. The version in the name changes whenever the
/// generated audio does, so a stale cache is never read.
public func defaultPlaybackFixturesDirectory() throws -> URL {
    try FileManager.default.url(
        for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false
    ).appendingPathComponent("\(appDirectoryName)/playback-fixtures-v1")
}

/// One continuous ramp split into two FLAC tracks, so any gap, repeat or click at the boundary
/// shows as a sample that isn't the next step of the ramp.
public struct RampAlbum: Sendable {
    public let tracks: [URL]
    let trackFrames: [Int]
    public let sampleRateHz: Int
    public let bitsPerSample: Int

    public var totalFrames: Int { trackFrames.reduce(0, +) }

    /// Frame `index` of the album, as the stereo 32-bit samples a device receives.
    public func frame(_ index: Int) -> (Int32, Int32) {
        let shift = Int32(32 - bitsPerSample)
        return (
            rampSample(index, channel: 0, bits: bitsPerSample) << shift,
            rampSample(index, channel: 1, bits: bitsPerSample) << shift
        )
    }
}

private func rampSample(_ frame: Int, channel: Int, bits: Int) -> Int32 {
    let span = 1 << bits
    return Int32((frame * 7 + channel * 12_345) % span - span / 2)
}

/// Makes the album the first time it's asked for at this rate and depth, and returns it. The
/// first track ends partway through a FLAC block, so the boundary isn't on a convenient frame.
public func rampAlbum(sampleRateHz: Int, bitsPerSample: Int, in directory: URL) throws
    -> RampAlbum
{
    let frames = [sampleRateHz + 123, sampleRateHz / 2]
    var tracks: [URL] = []
    var start = 0
    for (index, count) in frames.enumerated() {
        let url = directory.appendingPathComponent(
            "ramp-\(sampleRateHz)-\(bitsPerSample)-\(index + 1).flac")
        let first = start
        try makeFLAC(
            at: url, sampleRateHz: sampleRateHz, bitsPerSample: bitsPerSample, frames: count
        ) { frame, channel in
            rampSample(first + frame, channel: channel, bits: bitsPerSample)
        }
        tracks.append(url)
        start += count
    }
    return RampAlbum(
        tracks: tracks, trackFrames: frames, sampleRateHz: sampleRateHz,
        bitsPerSample: bitsPerSample)
}

/// One continuous sine, a different phase on each channel, split into two FLAC tracks as a
/// `RampAlbum` is, for output that resamples: a ramp's steps would ring, but any gap, repeat or
/// seam at the join still shows as samples off the sine.
struct SineAlbum: Sendable {
    let tracks: [URL]
    let trackFrames: [Int]
    let sampleRateHz: Int

    var totalFrames: Int { trackFrames.reduce(0, +) }
    var durationSeconds: Double { Double(totalFrames) / Double(sampleRateHz) }

    static let frequencyHz = 997.0
    static let amplitude = 0.5

    /// The album's signal `seconds` in, from -1 to 1.
    func value(atSeconds seconds: Double, channel: Int) -> Double {
        Self.amplitude * sin(2 * .pi * Self.frequencyHz * seconds + Double(channel) * .pi / 2)
    }
}

/// Makes the album the first time it's asked for at this rate and depth, and returns it.
func sineAlbum(sampleRateHz: Int, bitsPerSample: Int, in directory: URL) throws
    -> SineAlbum
{
    let frames = [sampleRateHz + 123, sampleRateHz / 2]
    let album = SineAlbum(tracks: [], trackFrames: frames, sampleRateHz: sampleRateHz)
    let scale = Double(1 << (bitsPerSample - 1))
    var tracks: [URL] = []
    var start = 0
    for (index, count) in frames.enumerated() {
        let url = directory.appendingPathComponent(
            "sine-\(sampleRateHz)-\(bitsPerSample)-\(index + 1).flac")
        let first = start
        try makeFLAC(
            at: url, sampleRateHz: sampleRateHz, bitsPerSample: bitsPerSample, frames: count
        ) { frame, channel in
            let seconds = Double(first + frame) / Double(sampleRateHz)
            return Int32((album.value(atSeconds: seconds, channel: channel) * scale).rounded())
        }
        tracks.append(url)
        start += count
    }
    return SineAlbum(tracks: tracks, trackFrames: frames, sampleRateHz: sampleRateHz)
}

/// Two minutes of 24-bit 192 kHz FLAC: a sine with noise in the low bits, so it costs about as
/// much to decode as a real hi-res recording. Made the first time it's asked for.
public func hiResTrack(in directory: URL) throws -> URL {
    let rate = 192_000
    let url = directory.appendingPathComponent("sine-noise-192000-24.flac")
    var noise = SplitMix64(seed: 192)
    try makeFLAC(at: url, sampleRateHz: rate, bitsPerSample: 24, frames: rate * 120) {
        frame, channel in
        let sine = 0.1 * sin(2 * .pi * 997 * Double(frame) / Double(rate) + Double(channel))
        return Int32(sine * Double(1 << 23)) + Int32(truncatingIfNeeded: noise.next() >> 52) - 2048
    }
    return url
}

/// Writes stereo PCM from `sample` as WAV, then encodes it, unless `url` already exists. Works in
/// a scratch directory and renames the result into place, so a test running at the same time
/// never sees half a file.
private func makeFLAC(
    at url: URL, sampleRateHz: Int, bitsPerSample: Int, frames: Int,
    sample: (_ frame: Int, _ channel: Int) -> Int32
) throws {
    let manager = FileManager.default
    if manager.fileExists(atPath: url.path) { return }
    try manager.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let scratch = manager.temporaryDirectory.appendingPathComponent(
        "playback-fixture-\(UUID().uuidString)")
    try manager.createDirectory(at: scratch, withIntermediateDirectories: true)
    let made = Result {
        let wav = scratch.appendingPathComponent("source.wav")
        let flac = scratch.appendingPathComponent("encoded.flac")
        try writeWAV(
            at: wav, sampleRateHz: sampleRateHz, bitsPerSample: bitsPerSample, frames: frames,
            sample: sample)
        try runAfconvert(["-f", "flac", "-d", "flac", wav.path, flac.path])
        guard rename(flac.path, url.path) == 0 else {
            throw FixtureError.unexpectedSeed(
                "couldn't move \(flac.path) into place: errno \(errno)")
        }
    }
    try manager.removeItem(at: scratch)
    try made.get()
}

func writeWAV(
    at url: URL, sampleRateHz: Int, bitsPerSample: Int, frames: Int,
    sample: (Int, Int) -> Int32
) throws {
    let channels = 2
    let bytesPerSample = bitsPerSample / 8
    let dataBytes = frames * channels * bytesPerSample
    var header = Data("RIFF".utf8)
    header.appendLittleEndian(UInt32(36 + dataBytes))
    header.append(contentsOf: Array("WAVEfmt ".utf8))
    header.appendLittleEndian(UInt32(16))
    header.appendLittleEndian(UInt16(1))  // integer PCM
    header.appendLittleEndian(UInt16(channels))
    header.appendLittleEndian(UInt32(sampleRateHz))
    header.appendLittleEndian(UInt32(sampleRateHz * channels * bytesPerSample))
    header.appendLittleEndian(UInt16(channels * bytesPerSample))
    header.appendLittleEndian(UInt16(bitsPerSample))
    header.append(contentsOf: Array("data".utf8))
    header.appendLittleEndian(UInt32(dataBytes))

    FileManager.default.createFile(atPath: url.path, contents: header)
    let file = try FileHandle(forWritingTo: url)
    try file.seekToEnd()
    // A second of audio at a time, so two minutes at 192 kHz never sits in memory at once.
    var block = Data(capacity: sampleRateHz * channels * bytesPerSample)
    for frame in 0..<frames {
        for channel in 0..<channels {
            withUnsafeBytes(of: sample(frame, channel).littleEndian) {
                block.append(contentsOf: $0.prefix(bytesPerSample))
            }
        }
        if (frame + 1) % sampleRateHz == 0 || frame + 1 == frames {
            try file.write(contentsOf: block)
            block.removeAll(keepingCapacity: true)
        }
    }
    try file.close()
}
