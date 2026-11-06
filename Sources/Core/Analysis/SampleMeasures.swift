import Accelerate
import Foundation

/// The measures read from the samples themselves: effective bits, identical channels and
/// clipped runs from the samples as decoded, and the peak, true peak and DR blocks from each
/// channel as float.
final class SampleMeasures {
    let channels: Int
    /// Integer samples hold their stored bits at the top of 32.
    private let integerFullScale: Int32?
    private var orOfSamples: UInt32 = 0
    private var channelsDiffer = false
    private var runLengths: [Int]
    private(set) var clippedRuns = 0
    private var peak: Float = 0
    private let truePeaks: [TruePeakMeter]
    private let blockFrames: Int
    private var blocks: [[DynamicRangeBlock]]
    private var current: [DynamicRangeBlock]

    /// `storedBits` for integer samples, nil for float ones.
    init(channels: Int, sampleRateHz: Double, storedBits: Int?) {
        self.channels = channels
        integerFullScale = storedBits.map { bits in
            Int32(truncatingIfNeeded: (Int64(1) << (bits - 1) - 1) << (32 - bits))
        }
        runLengths = Array(repeating: 0, count: channels)
        truePeaks = (0..<channels).map { _ in TruePeakMeter() }
        blockFrames = max(1, Int(sampleRateHz * AnalysisRules.dynamicRangeBlockSeconds))
        blocks = Array(repeating: [], count: channels)
        current = Array(repeating: DynamicRangeBlock(), count: channels)
    }

    /// `frames` interleaved integer samples, as decoded.
    func addIntegers(_ samples: UnsafePointer<Int32>, frames: Int) {
        guard let fullScale = integerFullScale else {
            preconditionFailure("integer samples for a float measure")
        }
        var or: UInt32 = 0
        for index in 0..<frames * channels {
            let sample = samples[index]
            or |= UInt32(bitPattern: sample)
            countClipped(sample >= fullScale || sample <= -fullScale, channel: index % channels)
        }
        orOfSamples |= or
        if channels > 1, !channelsDiffer {
            for frame in 0..<frames where samples[frame * channels] != samples[frame * channels + 1]
            {
                channelsDiffer = true
                break
            }
        }
    }

    /// `frames` interleaved float samples, as decoded.
    func addFloats(_ samples: UnsafePointer<Float>, frames: Int) {
        for index in 0..<frames * channels {
            countClipped(
                abs(samples[index]) >= AnalysisRules.clippedFloatLevel, channel: index % channels)
        }
        if channels > 1, !channelsDiffer {
            for frame in 0..<frames where samples[frame * channels] != samples[frame * channels + 1]
            {
                channelsDiffer = true
                break
            }
        }
    }

    private func countClipped(_ atFullScale: Bool, channel: Int) {
        if atFullScale {
            runLengths[channel] += 1
            return
        }
        if runLengths[channel] >= AnalysisRules.clippedRunSamples { clippedRuns += 1 }
        runLengths[channel] = 0
    }

    /// One channel's samples as float, from -1 to 1.
    func addChannel(_ samples: UnsafeBufferPointer<Float>, channel: Int) {
        guard let base = samples.baseAddress, !samples.isEmpty else { return }
        var most: Float = 0
        vDSP_maxmgv(base, 1, &most, vDSP_Length(samples.count))
        peak = max(peak, most)
        truePeaks[channel].add(samples)
        var start = 0
        while start < samples.count {
            let count = min(samples.count - start, blockFrames - current[channel].frames)
            var squares: Float = 0
            vDSP_svesq(base + start, 1, &squares, vDSP_Length(count))
            vDSP_maxmgv(base + start, 1, &most, vDSP_Length(count))
            current[channel].add(squares: Double(squares), peak: most, frames: count)
            if current[channel].frames == blockFrames {
                blocks[channel].append(current[channel])
                current[channel] = DynamicRangeBlock()
            }
            start += count
        }
    }

    /// The trailing zero bits every integer sample has, as effective bits; nil for float
    /// samples or when every sample is zero.
    var effectiveBits: Int? {
        guard integerFullScale != nil, orOfSamples != 0 else { return nil }
        return 32 - orOfSamples.trailingZeroBitCount
    }

    var identicalChannels: Bool? { channels > 1 ? !channelsDiffer : nil }

    /// Ends the runs still going at the end of the file.
    func finish() {
        for channel in 0..<channels where runLengths[channel] >= AnalysisRules.clippedRunSamples {
            clippedRuns += 1
        }
        runLengths = Array(repeating: 0, count: channels)
    }

    var peakDBFS: Double? { peak > 0 ? 20 * log10(Double(peak)) : nil }

    var truePeakDBTP: Double? {
        let most = max(peak, truePeaks.map(\.peak).max() ?? 0)
        return most > 0 ? 20 * log10(Double(most)) : nil
    }

    /// The DR meters' score: per channel, the second-highest block peak against the RMS of the
    /// loudest `dynamicRangeLoudestShare` of blocks, averaged over the channels and rounded. A
    /// file shorter than one block is one block.
    var dynamicRange: Int? {
        let scores = (0..<channels).compactMap { channel -> Double? in
            var all = blocks[channel]
            if all.isEmpty, current[channel].frames > 0 { all = [current[channel]] }
            let peaks = all.map(\.peak).sorted(by: >)
            guard let first = peaks.first, first > 0 else { return nil }
            let secondPeak = Double(peaks.count > 1 ? peaks[1] : first)
            let loudest = all.map(\.meanSquare).sorted(by: >)
                .prefix(max(1, Int(Double(all.count) * AnalysisRules.dynamicRangeLoudestShare)))
            // DR meters take the RMS of a sine as its peak, so twice the mean square.
            let rms = (2 * loudest.reduce(0, +) / Double(loudest.count)).squareRoot()
            guard rms > 0, secondPeak > 0 else { return nil }
            return 20 * log10(secondPeak / rms)
        }
        guard !scores.isEmpty else { return nil }
        return Int((scores.reduce(0, +) / Double(scores.count)).rounded())
    }
}

/// One channel's sum of squares and peak over a DR block.
struct DynamicRangeBlock {
    private(set) var squares = 0.0
    private(set) var peak: Float = 0
    private(set) var frames = 0

    mutating func add(squares: Double, peak: Float, frames: Int) {
        self.squares += squares
        self.peak = max(self.peak, peak)
        self.frames += frames
    }

    var meanSquare: Double { frames > 0 ? squares / Double(frames) : 0 }
}
