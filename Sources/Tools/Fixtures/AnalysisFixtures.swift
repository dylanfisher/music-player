import Accelerate
import Foundation

/// Broadband test audio with known properties, for the analysis and its verdicts (phase 45):
/// white noise made by an inverse FFT, so a low-pass is exact to the bin, at -20 dBFS RMS
/// unless a case says otherwise.
public enum AnalysisFixture: String, CaseIterable, Sendable {
    /// 16/44.1, every bin to Nyquist.
    case fullBand
    /// The same, nothing above 16 kHz, as a 128k MP3 cuts.
    case lowPass16k
    /// The same, nothing above 19 kHz, as a 192–256k MP3 cuts.
    case lowPass19k
    /// The full band through AAC at 128 kbps with AudioToolbox.
    case aac
    /// The same decoded back into a FLAC.
    case aacRoundTrip
    /// 24/96 holding 16/44.1 content: nothing above 22.05 kHz.
    case upsampled
    /// 24-bit samples whose bottom 8 bits are zero.
    case padded
    /// The same samples on left and right.
    case identicalChannels
    /// A 100 Hz sine over full scale, flattened at full scale, under the noise.
    case clipped
    /// 24/96, every bin to Nyquist, all 24 bits used.
    case hiRes

    var sampleRateHz: Int { [.upsampled, .hiRes].contains(self) ? 96_000 : 44_100 }
    var bitsPerSample: Int { [.upsampled, .padded, .hiRes].contains(self) ? 24 : 16 }

    /// Where the noise stops.
    var cutoffHz: Double {
        switch self {
        case .lowPass16k: 16_000
        case .lowPass19k: 19_000
        case .upsampled: 22_050
        default: Double(sampleRateHz) / 2
        }
    }
}

/// The seconds a test's fixture lasts: long enough for 30 FFT frames at 44.1 kHz.
public let analysisFixtureSeconds = 6

/// Makes `fixture` the first time it's asked for at this length, in `directory`, and returns it.
public func analysisFixture(
    _ fixture: AnalysisFixture, seconds: Int = analysisFixtureSeconds, in directory: URL
) throws -> URL {
    let rate = fixture.sampleRateHz
    let bits = fixture.bitsPerSample
    let name = "analysis-\(fixture.rawValue)-\(rate)-\(bits)-\(seconds)s"
    let url = directory.appendingPathComponent(name + (fixture == .aac ? ".m4a" : ".flac"))
    // Before the noise, which takes longer to make than a test takes to read the file.
    if FileManager.default.fileExists(atPath: url.path) { return url }
    let noise = (0..<2).map { channel in
        bandLimitedNoise(
            rateHz: rate, cutoffHz: fixture.cutoffHz,
            rms: fixture == .clipped ? 0.05 : 0.1,
            seed: fixture == .identicalChannels ? 1 : UInt64(channel + 1))
    }
    let period = noise[0].count
    let scale = Double(1 << (bits - 1))
    let sample = { (frame: Int, channel: Int) -> Int32 in
        var value = noise[channel][frame % period]
        if fixture == .clipped {
            value += 1.2 * sin(2 * .pi * 100 * Double(frame) / Double(rate))
        }
        // The padded file's samples are 16-bit ones shifted up.
        let depth = fixture == .padded ? Double(1 << 15) : scale
        let code = Int32(max(-depth, min(depth - 1, (value * depth).rounded())))
        return fixture == .padded ? code << 8 : code
    }
    try makeEncoded(
        at: url, sampleRateHz: rate, bitsPerSample: bits, frames: rate * seconds,
        afconvert: [.aac, .aacRoundTrip].contains(fixture) ? aacArguments : flacArguments,
        then: fixture == .aacRoundTrip ? flacArguments : nil, sample: sample)
    return url
}

/// AAC at 128 kbps, which Apple's encoder cuts near 17.5 kHz.
private let aacArguments = SeedKind.aac.afconvertArguments! + ["-b", "128000"]
private let flacArguments = SeedKind.flac16.afconvertArguments!

/// One period of noise, 2^17 frames, with the same power in every bin from the first up to
/// `cutoffHz` and none above or at DC, at `rms`.
private func bandLimitedNoise(rateHz: Int, cutoffHz: Double, rms: Double, seed: UInt64)
    -> [Double]
{
    let log2Frames = vDSP_Length(17)
    let frames = 1 << 17
    let bins = frames / 2
    var random = SplitMix64(seed: seed)
    var real = [Float](repeating: 0, count: bins)
    var imaginary = [Float](repeating: 0, count: bins)
    for bin in 1..<bins where Double(bin) * Double(rateHz) / Double(frames) < cutoffHz {
        let phase = Double.random(in: 0..<2 * .pi, using: &random)
        real[bin] = Float(cos(phase))
        imaginary[bin] = Float(sin(phase))
    }
    var signal = [Float](repeating: 0, count: frames)
    guard let setup = vDSP_create_fftsetup(log2Frames, FFTRadix(kFFTRadix2)) else {
        preconditionFailure("vDSP couldn't set up an FFT of \(frames) points")
    }
    defer { vDSP_destroy_fftsetup(setup) }
    real.withUnsafeMutableBufferPointer { real in
        imaginary.withUnsafeMutableBufferPointer { imaginary in
            var split = DSPSplitComplex(realp: real.baseAddress!, imagp: imaginary.baseAddress!)
            vDSP_fft_zrip(setup, &split, 1, log2Frames, FFTDirection(FFT_INVERSE))
            signal.withUnsafeMutableBytes { bytes in
                vDSP_ztoc(
                    &split, 1, bytes.bindMemory(to: DSPComplex.self).baseAddress!, 2,
                    vDSP_Length(bins))
            }
        }
    }
    let samples = signal.map(Double.init)
    let measured = (samples.reduce(0) { $0 + $1 * $1 } / Double(frames)).squareRoot()
    return samples.map { $0 * rms / measured }
}
