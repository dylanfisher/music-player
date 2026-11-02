/// Whether the samples reach the sink unchanged.
public enum SignalVerdict: Sendable, Equatable {
    /// Nothing is loaded, so there are no samples to judge.
    case idle
    case bitPerfect
    /// Each thing that changes the samples, in the order the samples meet them.
    case changed([SignalChange])
    /// The file's bytes go unchanged to a network renderer, which decodes them, so what it
    /// plays can't be checked from this Mac.
    case unverifiable
}

public enum SignalChange: Sendable, Equatable {
    case decoderResamples(fromHz: Double, toHz: Double)
    case decoderRemixes(fromChannels: UInt32, toChannels: UInt32)
    /// The decoder's output can't hold every value the file's samples can take.
    case decoderLosesPrecision(SignalFormat)
    /// The device runs at another rate than the samples written to it, so the HAL resamples.
    case deviceResamples(fromHz: Double, toHz: Double)
    case deviceRemixes(fromChannels: UInt32, toChannels: UInt32)
    case deviceLosesPrecision(SignalFormat)
    /// The system mixes other apps' sound into the stream, in floating point.
    case mixableFormat
    case hogModeFree
    case hogModeHeld(byPID: Int32)
    /// The lowest volume control below unity.
    case deviceVolume(VolumeControl)
    case digitalVolume(gain: Double)
    case deviceNotConnected
    case deviceUnreadable(String)
}

/// Judges `path` against the file: bit-perfect only when every stage passes each sample through
/// as the file holds it. Unity means exactly 1, since any other scalar rewrites every sample.
public func signalVerdict(_ path: SignalPath) -> SignalVerdict {
    guard let track = path.track else { return .idle }
    var changes = decoderChanges(track)
    switch path.sink {
    case .device(let sink):
        changes += deviceChanges(sink, decoded: track.decoded, source: sourcePrecision(track))
    case .renderer:
        return .unverifiable
    }
    return changes.isEmpty ? .bitPerfect : .changed(changes)
}

private func decoderChanges(_ track: TrackSignal) -> [SignalChange] {
    let (file, decoded) = (track.file, track.decoded)
    var changes: [SignalChange] = []
    if decoded.sampleRateHz != file.sampleRateHz {
        changes.append(.decoderResamples(fromHz: file.sampleRateHz, toHz: decoded.sampleRateHz))
    }
    if decoded.channels != file.channels {
        changes.append(.decoderRemixes(fromChannels: file.channels, toChannels: decoded.channels))
    }
    if !decoded.holds(sourcePrecision(track)) { changes.append(.decoderLosesPrecision(decoded)) }
    return changes
}

private func deviceChanges(_ sink: DeviceSink, decoded: SignalFormat, source: Precision)
    -> [SignalChange]
{
    var changes: [SignalChange] = []
    if sink.gain != 1 { changes.append(.digitalVolume(gain: sink.gain)) }
    let device: DeviceSignal
    switch sink.state {
    case .notConnected: return changes + [.deviceNotConnected]
    case .unreadable(let why): return changes + [.deviceUnreadable(why)]
    case .connected(let signal): device = signal
    }
    if device.nominalSampleRateHz != decoded.sampleRateHz {
        changes.append(
            .deviceResamples(fromHz: decoded.sampleRateHz, toHz: device.nominalSampleRateHz))
    }
    if device.physical.channels != decoded.channels {
        changes.append(
            .deviceRemixes(fromChannels: decoded.channels, toChannels: device.physical.channels))
    }
    if !device.physical.holds(source) { changes.append(.deviceLosesPrecision(device.physical)) }
    if device.isMixable { changes.append(.mixableFormat) }
    switch device.hogMode {
    case .thisProcess: break
    case .free: changes.append(.hogModeFree)
    case .otherProcess(let pid): changes.append(.hogModeHeld(byPID: pid))
    }
    if let lowest = device.volumes.filter({ $0.scalar != 1 }).min(by: { $0.scalar < $1.scalar }) {
        changes.append(.deviceVolume(lowest))
    }
    return changes
}

/// The values a sample can take: integers of some width, or floats of some width.
private struct Precision {
    var bits: UInt32
    var isFloat: Bool
}

/// The file's own precision, or for a lossy codec, which has none, the decoder's output.
private func sourcePrecision(_ track: TrackSignal) -> Precision {
    let format = track.file.bitsPerChannel == nil ? track.decoded : track.file
    return Precision(bits: format.bitsPerChannel ?? 0, isFloat: format.isFloat)
}

extension SignalFormat {
    /// Whether every sample of `source` has an exact value in this format. Integers widen into
    /// wider integers, and into floats whose significand holds them: 24 bits in a 32-bit float,
    /// 53 in a 64-bit one. A float source fits only a float at least as wide.
    fileprivate func holds(_ source: Precision) -> Bool {
        guard let bits = bitsPerChannel else { return false }
        if source.isFloat { return isFloat && bits >= source.bits }
        guard isFloat else { return bits >= source.bits }
        switch bits {
        case 32: return source.bits <= 24
        case 64: return source.bits <= 53
        default: return false
        }
    }
}
