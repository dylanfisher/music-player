import DisplayText
import Foundation
import Metadata
import Playback

/// What the signal path panel shows: the verdict as a badge with the reasons after it, then the
/// stages the samples pass through, from the file to the device or renderer.
struct SignalPathLines: Equatable {
    /// One step of the path, such as `File` with `44.1 kHz · 16-bit` and `FLAC · stereo`.
    struct Stage: Equatable {
        var title: String
        var value: String
        /// Smaller text under the value; empty for none.
        var note: String
        /// Whether something here changes the samples, which tints the stage.
        var changes: Bool
    }

    /// Picks the badge's color.
    enum Tone: Equatable {
        case bitPerfect, changed, neutral
    }

    var badge: String
    var tone: Tone
    var detail: String
    var stages: [Stage]
}

/// The panel's text for `path`, or for no output at all when it's nil.
func signalPathLines(_ path: SignalPath?) -> SignalPathLines {
    guard let path else {
        return SignalPathLines(badge: "No output device", tone: .neutral, detail: "", stages: [])
    }
    var lines = SignalPathLines(badge: "", tone: .neutral, detail: "", stages: [])
    var changes: [SignalChange] = []
    switch signalVerdict(path) {
    case .idle: lines.badge = "Nothing playing"
    case .bitPerfect: (lines.badge, lines.tone) = ("Bit-perfect", .bitPerfect)
    case .changed(let found):
        changes = found
        let reasons = found.map(describe).joined(separator: "; ")
        (lines.badge, lines.tone) = (badge(for: found), .changed)
        lines.detail = reasons.prefix(1).uppercased() + reasons.dropFirst()
    case .unverifiable:
        lines.badge = "Can't be checked"
        lines.detail = "Sent unchanged to a network renderer, which decodes it"
    }
    if let track = path.track {
        lines.stages.append(
            .init(
                title: "File", value: value(of: track.file),
                note: note([track.file.codecName, channels(track.file.channels)]),
                changes: false))
    }
    switch path.sink {
    case .device(let sink):
        let decoderChanges = changes.filter(\.isTheDecoders)
        if let track = path.track, !decoderChanges.isEmpty {
            lines.stages.append(decoderStage(track))
        }
        lines.stages.append(
            deviceStage(
                sink, isDoP: path.track?.decoded.formatID == dopFormatID,
                changes: changes.contains { !$0.isTheDecoders }))
    case .renderer(let sink): lines.stages.append(rendererStage(sink))
    }
    return lines
}

/// "Not guaranteed bit-perfect" when every change is one only another app's sound would make:
/// usually nothing else plays, and then the samples reach the device unchanged.
private func badge(for changes: [SignalChange]) -> String {
    if changes.contains(where: { if case .converted = $0 { true } else { false } }) {
        return "Converted"
    }
    let onlyOtherApps = changes.allSatisfy { change in
        switch change {
        case .mixableFormat, .hogModeFree: true
        default: false
        }
    }
    return onlyOtherApps ? "Not guaranteed bit-perfect" : "Not bit-perfect"
}

extension SignalChange {
    /// Whether the decoder makes the change, rather than the device or macOS after it.
    fileprivate var isTheDecoders: Bool {
        switch self {
        case .converted, .decoderResamples, .decoderRemixes, .channelOrderAssumed,
            .decoderLosesPrecision:
            true
        default: false
        }
    }
}

/// Shown only when the decoder changes the samples, so a plain path is file, then device.
private func decoderStage(_ track: TrackSignal) -> SignalPathLines.Stage {
    let (from, to) = (track.file.channels, track.decoded.channels)
    let mix = to < from ? "downmixed from \(from)" : nil
    return .init(
        title: track.isConverted ? "Converted" : "Decoder", value: value(of: track.decoded),
        note: note([channels(to), mix]), changes: true)
}

/// DoP is never scaled, so the digital volume doesn't apply while it plays (ADR 0064).
private func deviceStage(_ sink: DeviceSink, isDoP: Bool, changes: Bool) -> SignalPathLines.Stage {
    var stage = SignalPathLines.Stage(title: sink.name, value: "", note: "", changes: changes)
    switch sink.state {
    case .notConnected: stage.value = "Not connected"
    case .unreadable(let why):
        stage.value = "Can't be read"
        stage.note = why
    case .connected(let device):
        stage.value = formatText(
            rateHz: device.nominalSampleRateHz, bits: device.physical.bitsPerChannel,
            isFloat: device.physical.isFloat)
        let access: String
        switch device.hogMode {
        case .thisProcess: access = "exclusive"
        case .free: access = "shared with other apps"
        case .otherProcess: access = "held by another app"
        }
        let digital = isDoP || sink.gain == 1 ? nil : "volume \(decibels(sink.gain))"
        let control = device.volumes.filter { $0.scalar != 1 }.min { $0.scalar < $1.scalar }
            .map { "device volume \(percent($0.scalar))" }
        stage.note = note([isDoP ? "DoP" : nil, access, digital, control])
    }
    return stage
}

private func rendererStage(_ sink: RendererSink) -> SignalPathLines.Stage {
    let gapless: String?
    switch sink.gapless {
    case .unknown: gapless = nil
    case .nextURI: gapless = "gapless"
    case .afterStop(let reason): gapless = "not gapless: \(reason)"
    }
    let volume = sink.volumeIsReceivers ? "receiver's volume" : "its own volume"
    return .init(
        title: sink.name,
        value: sink.contentType == nil ? "Nothing loaded" : "Plays the file itself",
        note: note([gapless, volume]), changes: false)
}

private func describe(_ change: SignalChange) -> String {
    switch change {
    case .converted(let format):
        "the device can't take the file's format, so it's converted to \(value(of: format))"
    case .decoderResamples(let from, let to):
        "the decoder resamples \(kilohertz(from)) kHz to \(kilohertz(to)) kHz"
    case .decoderRemixes(let from, let to):
        to < from
            ? "the decoder downmixes \(from) channels to \(to)"
            : "the decoder copies \(from) channels into \(to)"
    case .channelOrderAssumed:
        "the file doesn't name its channels, so the downmix assumes the WAV default order"
    case .decoderLosesPrecision(let format):
        "the decoder rounds the samples to \(depth(format))"
    case .deviceResamples(let from, let to):
        "the device runs at \(kilohertz(to)) kHz, so macOS resamples from \(kilohertz(from)) kHz"
    case .deviceRemixes(let from, let to):
        "macOS maps \(from) channels onto the device's \(to)"
    case .deviceLosesPrecision(let format):
        "the device's \(depth(format)) format rounds the samples"
    case .mixableFormat: "other apps' sound can be mixed in"
    case .hogModeFree: "the device isn't held for this app alone, as Hog Mode is off"
    case .hogModeHeld: "another app holds the device for itself"
    case .deviceVolume(let control):
        "the device's \(name(of: control.kind)) volume is at \(percent(control.scalar))"
    case .digitalVolume(let gain): "the digital volume is at \(decibels(gain))"
    case .deviceNotConnected: "the device isn't connected"
    case .deviceUnreadable(let why): "the device can't be read: \(why)"
    }
}

/// For example `44.1 kHz · 16-bit`, `44.1 kHz` for a lossy codec, which has no depth, or
/// `DSD128`.
private func value(of format: SignalFormat) -> String {
    switch format.formatID {
    case dsdFormatID: sampleRateText(Int(format.sampleRateHz))
    case dopFormatID: dopText(carrierRateHz: format.sampleRateHz)
    default:
        formatText(
            rateHz: format.sampleRateHz, bits: format.bitsPerChannel, isFloat: format.isFloat)
    }
}

/// The parts there are, joined by middle dots, the first capitalized: `Exclusive · volume -6 dB`.
private func note(_ parts: [String?]) -> String {
    let joined = parts.compactMap { $0 }.joined(separator: " · ")
    return joined.prefix(1).uppercased() + joined.dropFirst()
}

private func channels(_ count: UInt32) -> String {
    switch count {
    case 1: "mono"
    case 2: "stereo"
    default: "\(count) channels"
    }
}

/// `24-bit` or `32-bit float`.
private func depth(_ format: SignalFormat) -> String {
    depthText(bits: format.bitsPerChannel ?? 0, isFloat: format.isFloat)
}

private func name(of kind: VolumeControl.Kind) -> String {
    switch kind {
    case .virtualMain: "system"
    case .main: "main"
    case .channel(let channel): "channel \(channel)"
    }
}

/// Exactly 1 reads as unity; anything else rounds down, so a scalar just below 1 never reads as
/// 100%.
private func percent(_ scalar: Float) -> String {
    scalar == 1 ? "unity" : String(format: "%.1f%%", (Double(scalar) * 1000).rounded(.down) / 10)
}

private func decibels(_ gain: Double) -> String {
    gain <= 0 ? "silence" : String(format: "%.1f dB", 20 * log10(gain))
}
