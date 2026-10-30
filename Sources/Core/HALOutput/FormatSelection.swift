import CoreAudio

/// Picks the physical format that passes samples at `sampleRateHz` through unchanged, or nil if the
/// device has none.
///
/// Integer only: a float format means the HAL converts. Non-mixable wins over mixable, so the mixer
/// and system volume can't touch the samples. Then the widest samples win, because padding 16 or
/// 24 bits into 32 is exact.
func bitPerfectFormat(
    in available: [AudioStreamRangedDescription], sampleRateHz: Double
) -> AudioStreamBasicDescription? {
    let candidates = available.filter { ranged in
        let format = ranged.mFormat
        return format.mFormatID == kAudioFormatLinearPCM
            && format.mFormatFlags & kAudioFormatFlagIsFloat == 0
            && (ranged.mSampleRateRange.mMinimum...ranged.mSampleRateRange.mMaximum)
                .contains(sampleRateHz)
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
