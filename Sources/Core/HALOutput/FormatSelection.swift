import CoreAudio
import Playback

/// Picks the physical format that passes `channels` of samples at `sampleRateHz` through
/// unchanged, at least `minimumBits` wide and non-mixable if `nonMixableOnly`, or nil if the device
/// has none.
///
/// Integer only: a float format means the HAL converts. Non-mixable wins over mixable, so the mixer
/// and system volume can't touch the samples, but only when `allowNonMixable`: without hog mode a
/// non-mixable format would lock every other app out. Then the widest samples win, because padding
/// 16 or 24 bits into 32 is exact.
func bitPerfectFormat(
    in available: [AudioStreamRangedDescription], sampleRateHz: Double, channels: UInt32,
    minimumBits: UInt32 = 0, nonMixableOnly: Bool = false, allowNonMixable: Bool
) -> AudioStreamBasicDescription? {
    let candidates = available.filter { ranged in
        let format = PhysicalFormat(ranged)
        return format.carries(sampleRateHz: sampleRateHz, channels: channels)
            && format.bitsPerChannel >= minimumBits && (allowNonMixable || format.isMixable)
            && !(nonMixableOnly && format.isMixable)
    }
    func rank(_ ranged: AudioStreamRangedDescription) -> (Int, UInt32) {
        let nonMixable = ranged.mFormat.mFormatFlags & kAudioFormatFlagIsNonMixable != 0
        return (nonMixable ? 1 : 0, ranged.mFormat.mBitsPerChannel)
    }
    guard let best = candidates.max(by: { rank($0) < rank($1) }) else { return nil }
    var format = best.mFormat
    format.mSampleRate = sampleRateHz
    return format
}

/// The format a PCM track of `channels` at `sampleRateHz` is converted to when no format carries
/// it unchanged, and the rate to run it at, or nil when the device has no PCM format allowed.
///
/// A format with at least the track's channels wins, so none is dropped, else the one with the
/// most. Then the rate nearest
/// the track's, at or above it before below it, and never below 44.1 kHz when there's one at or
/// above: AirPods offer 16 kHz mono for calls beside 48 kHz stereo, and a low-rate track mustn't
/// switch them to it. Then the track's own channel count, else the fewest above it, which a mono
/// track is copied into, else the most. Then float, which holds every integer source up to 24
/// bits exactly, and then the widest.
public func convertedFormat(
    in formats: [PhysicalFormat], sampleRateHz: Double, channels: UInt32, allowNonMixable: Bool
) -> (index: Int, sampleRateHz: Double)? {
    let lowest = max(sampleRateHz, lowestConvertedRateHz)
    func rate(_ format: PhysicalFormat) -> Double {
        min(max(lowest, format.sampleRateHz.lowerBound), format.sampleRateHz.upperBound)
    }
    func rank(_ format: PhysicalFormat) -> (Int, Int, Double, Int, Int, UInt32) {
        let rate = rate(format)
        let count = Int(format.channels)
        let enough = format.channels >= channels
        return (
            enough ? Int.max : count, rate >= lowest ? 1 : 0, rate >= lowest ? -rate : rate,
            format.channels == channels ? Int.max : enough ? -count : count,
            format.isFloat ? 1 : 0, format.bitsPerChannel
        )
    }
    let usable = formats.indices.filter {
        formats[$0].formatID == linearPCMFormatID && (allowNonMixable || formats[$0].isMixable)
    }
    guard let best = usable.max(by: { rank(formats[$0]) < rank(formats[$1]) }) else { return nil }
    return (best, rate(formats[best]))
}

/// CD's rate, the lowest a track is converted to when the device has a rate at or above it.
let lowestConvertedRateHz = 44_100.0
