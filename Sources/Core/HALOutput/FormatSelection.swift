import CoreAudio
import Playback

/// Picks the physical format that passes `channels` of samples at `sampleRateHz` through
/// unchanged, at least `minimumBits` wide, or nil if the device has none.
///
/// Integer only: a float format means the HAL converts. Non-mixable wins over mixable, so the mixer
/// and system volume can't touch the samples, but only when `allowNonMixable`: without hog mode a
/// non-mixable format would lock every other app out. Then the widest samples win, because padding
/// 16 or 24 bits into 32 is exact.
func bitPerfectFormat(
    in available: [AudioStreamRangedDescription], sampleRateHz: Double, channels: UInt32,
    minimumBits: UInt32 = 0, allowNonMixable: Bool
) -> AudioStreamBasicDescription? {
    let candidates = available.filter { ranged in
        let format = PhysicalFormat(ranged)
        return format.carries(sampleRateHz: sampleRateHz, channels: channels)
            && format.bitsPerChannel >= minimumBits && (allowNonMixable || format.isMixable)
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
