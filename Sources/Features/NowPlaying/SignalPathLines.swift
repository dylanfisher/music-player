import DisplayText
import Foundation
import Playback

/// What the signal path panel shows: the verdict as a badge with the reasons after it, then one
/// row per stage.
struct SignalPathLines: Equatable {
    struct Row: Equatable {
        var label: String
        var value: String
    }

    /// Picks the badge's color.
    enum Tone: Equatable {
        case bitPerfect, changed, neutral
    }

    var badge: String
    var tone: Tone
    var detail: String
    var rows: [Row]

    /// The rows in two columns, the file's stages on the left and the output's on the right, with
    /// an odd row on the left.
    var columns: [[Row]] {
        let split = (rows.count + 1) / 2
        return [Array(rows[..<split]), Array(rows[split...])].filter { !$0.isEmpty }
    }
}

/// The panel's text for `path`, or for no output at all when it's nil.
func signalPathLines(_ path: SignalPath?) -> SignalPathLines {
    guard let path else {
        return SignalPathLines(badge: "No output device", tone: .neutral, detail: "", rows: [])
    }
    var lines = SignalPathLines(badge: "", tone: .neutral, detail: "", rows: [])
    switch signalVerdict(path) {
    case .idle: lines.badge = "Nothing playing"
    case .bitPerfect: (lines.badge, lines.tone) = ("Bit-perfect", .bitPerfect)
    case .changed(let changes):
        let reasons = changes.map(describe).joined(separator: "; ")
        (lines.badge, lines.tone) = ("Not bit-perfect", .changed)
        lines.detail = reasons.prefix(1).uppercased() + reasons.dropFirst()
    case .unverifiable:
        lines.badge = "Can't be checked"
        lines.detail = "Sent unchanged to a network renderer, which decodes it"
    }
    if let track = path.track {
        lines.rows.append(.init(label: "File", value: describe(track.file)))
    }
    switch path.sink {
    case .device(let sink):
        if let track = path.track {
            lines.rows.append(.init(label: "Decoder", value: describe(track.decoded)))
        }
        lines.rows += deviceRows(sink)
    case .renderer(let sink): lines.rows += rendererRows(sink)
    }
    return lines
}

private func deviceRows(_ sink: DeviceSink) -> [SignalPathLines.Row] {
    let gain = "digital \(sink.gain == 1 ? "unity" : decibels(sink.gain))"
    switch sink.state {
    case .notConnected:
        return [.init(label: "Device", value: "\(sink.name), not connected")]
    case .unreadable(let why):
        return [.init(label: "Device", value: "\(sink.name), can't be read: \(why)")]
    case .connected(let device):
        let mixing = device.isMixable ? "mixable" : "non-mixable"
        let hog: String
        switch device.hogMode {
        case .thisProcess: hog = "held by this app"
        case .free: hog = "not held"
        case .otherProcess(let pid): hog = "held by another process (pid \(pid))"
        }
        let volumes =
            device.volumes.isEmpty
            ? "no device controls"
            : device.volumes.map { "\(name(of: $0.kind)) \(percent($0.scalar))" }
                .joined(separator: ", ")
        return [
            .init(
                label: "Device",
                value:
                    "\(sink.name) at \(kilohertz(device.nominalSampleRateHz)) kHz: "
                    + "\(describe(device.physical)), \(mixing)"),
            .init(label: "Takes", value: describe(device.formats)),
            .init(label: "Hog mode", value: hog),
            .init(label: "Volume", value: "\(volumes); \(gain)"),
        ]
    }
}

private func rendererRows(_ sink: RendererSink) -> [SignalPathLines.Row] {
    let gapless: String
    switch sink.gapless {
    case .unknown: gapless = "not known yet"
    case .nextURI: gapless = "yes, the next track is handed over while one plays"
    case .afterStop(let why): gapless = "no, each track starts after the last stops: \(why)"
    }
    return [
        .init(label: "Renderer", value: "\(sink.name) at \(sink.address)"),
        .init(
            label: "Sent",
            value: sink.contentType.map { "the file's own bytes over HTTP, as \($0)" }
                ?? "nothing loaded"),
        .init(label: "Decoder", value: "the renderer's own"),
        .init(label: "Gapless", value: gapless),
        .init(
            label: "Volume",
            value: sink.volumeIsReceivers
                ? "the receiver's own, set with the Receiver volume commands"
                : "the renderer's own; the app sends none"),
    ]
}

/// For example `44.1, 48, 88.2, 96 kHz; 2 ch 16-bit int, 2 ch 24-bit int`: the rates, then each
/// layout once, whatever rates it comes at.
private func describe(_ formats: DeviceFormats) -> String {
    let rates = formats.sampleRatesHz.map(kilohertz).joined(separator: ", ")
    var layouts: [String] = []
    for format in formats.formats {
        let layout =
            "\(format.channels) ch \(sampleType(bits: format.bitsPerChannel, isFloat: format.isFloat))"
        if !layouts.contains(layout) { layouts.append(layout) }
    }
    return "\(rates.isEmpty ? "no rates" : rates + " kHz"); "
        + (layouts.isEmpty ? "no formats" : layouts.joined(separator: ", "))
}

private func describe(_ change: SignalChange) -> String {
    switch change {
    case .decoderResamples(let from, let to):
        "the decoder resamples \(kilohertz(from)) kHz to \(kilohertz(to)) kHz"
    case .decoderRemixes(let from, let to): "the decoder mixes \(from) channels into \(to)"
    case .decoderLosesPrecision(let format):
        "the decoder rounds the samples to \(sampleType(format))"
    case .deviceResamples(let from, let to):
        "the device runs at \(kilohertz(to)) kHz, so macOS resamples from \(kilohertz(from)) kHz"
    case .deviceRemixes(let from, let to):
        "macOS maps \(from) channels onto the device's \(to)"
    case .deviceLosesPrecision(let format):
        "the device's \(sampleType(format)) format rounds the samples"
    case .mixableFormat: "the format is mixable, so macOS mixes other apps' sound in"
    case .hogModeFree: "hog mode isn't held, so other apps can play through the device"
    case .hogModeHeld(let pid): "another process (pid \(pid)) holds hog mode"
    case .deviceVolume(let control):
        "the device's \(name(of: control.kind)) volume is at \(percent(control.scalar))"
    case .digitalVolume(let gain): "the digital volume is at \(decibels(gain))"
    case .deviceNotConnected: "the device isn't connected"
    case .deviceUnreadable(let why): "the device can't be read: \(why)"
    }
}

/// For example `FLAC 24-bit int, 96 kHz, 2 ch`, or `MP3 44.1 kHz, 2 ch` for a lossy codec.
private func describe(_ format: SignalFormat) -> String {
    let codec =
        format.formatID == linearPCMFormatID
        ? "PCM"
        : format.formatID.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
            .uppercased()
    let sample = format.bitsPerChannel == nil ? "" : " \(sampleType(format)),"
    return "\(codec)\(sample) \(kilohertz(format.sampleRateHz)) kHz, \(format.channels) ch"
}

private func sampleType(_ format: SignalFormat) -> String {
    sampleType(bits: format.bitsPerChannel ?? 0, isFloat: format.isFloat)
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
