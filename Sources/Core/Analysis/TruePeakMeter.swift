import Accelerate
import Foundation

/// One channel's true peak: the highest magnitude of the signal 4× oversampled, as BS.1770
/// measures it, through a 48-tap interpolator split into a 12-tap filter per phase.
final class TruePeakMeter {
    static let phases = 4
    static let tapsPerPhase = 12

    /// Each phase's taps, reversed for `vDSP_conv`, which correlates: a Hann-windowed sinc
    /// cut at the original Nyquist frequency, each phase scaled to unit gain.
    private static let filters: [[Float]] = {
        let taps = phases * tapsPerPhase
        let center = Double(taps - 1) / 2
        let prototype = (0..<taps).map { tap in
            let x = (Double(tap) - center) / Double(phases)
            let sinc = x == 0 ? 1 : sin(.pi * x) / (.pi * x)
            let hann = 0.5 - 0.5 * cos(2 * .pi * (Double(tap) + 0.5) / Double(taps))
            return sinc * hann
        }
        return (0..<phases).map { phase in
            let taps = (0..<tapsPerPhase).map { prototype[$0 * phases + phase] }
            let gain = taps.reduce(0, +)
            return taps.reversed().map { Float($0 / gain) }
        }
    }()

    /// A bound on any phase's output as a multiple of the largest magnitude it reads: the larger
    /// sum of a phase's tap magnitudes, 1.80, with room for float rounding.
    private static let gainBound: Double = {
        let sums = filters.map { $0.reduce(0) { $0 + Double(abs($1)) } }
        // A 12-term float dot product rounds to within 12 × 2⁻²⁴ ≈ 7.2e-7 of its exact value
        // relative to the sum of the products' magnitudes, in any order, with or without fused
        // multiply-adds; 1e-5 covers that.
        return sums.max()! * (1 + 1e-5)
    }()

    private(set) var peak: Float = 0
    /// The last `tapsPerPhase - 1` samples, then the block being measured.
    private var buffer = [Float](repeating: 0, count: tapsPerPhase - 1)
    private var interpolated: [Float] = []

    func add(_ samples: UnsafeBufferPointer<Float>) {
        let history = Self.tapsPerPhase - 1
        buffer.removeSubrange(0..<buffer.count - history)
        buffer.append(contentsOf: samples)
        // The filter reads the history as well as the new samples, so the bound covers both.
        // A hop whose bound is no more than the peak can't raise it; skipping its filtering
        // leaves the peak as it would be. The absolute term covers products rounded to
        // subnormals.
        var loudest: Float = 0
        vDSP_maxmgv(buffer, 1, &loudest, vDSP_Length(buffer.count))
        if loudest == 0
            || Double(loudest) * Self.gainBound + Double(Float.leastNormalMagnitude)
                <= Double(peak)
        {
            return
        }
        if interpolated.count < samples.count {
            interpolated = [Float](repeating: 0, count: samples.count)
        }
        var most: Float = 0
        for filter in Self.filters {
            vDSP_conv(
                buffer, 1, filter, 1, &interpolated, 1, vDSP_Length(samples.count),
                vDSP_Length(Self.tapsPerPhase))
            vDSP_maxmgv(interpolated, 1, &most, vDSP_Length(samples.count))
            peak = max(peak, most)
        }
    }
}
