import DisplayText

/// A DSD rate is 64, 128, 256 or 512 times 44.1 kHz, or more rarely 48 kHz.
private let dsdMultipliers: Set<Int> = [64, 128, 256, 512]
private let dsdBaseRatesHz = [44_100, 48_000]

/// 128 for DSD128's 5,644,800 Hz, or nil for a rate that isn't a DSD rate. No PCM rate is that
/// high, so the rate alone says a track is DSD.
func dsdMultiplier(_ rateHz: Int) -> Int? {
    for base in dsdBaseRatesHz where rateHz % base == 0 && dsdMultipliers.contains(rateHz / base) {
        return rateHz / base
    }
    return nil
}

/// How every view names a track's rate: "DSD128" for a DSD rate, otherwise "96 kHz".
func sampleRateText(_ rateHz: Int) -> String {
    dsdMultiplier(rateHz).map { "DSD\($0)" } ?? "\(kilohertz(Double(rateHz))) kHz"
}
