import AppKit
import Testing

@testable import NowPlaying
@testable import Playback

private let flac = SignalFormat(
    formatID: "flac", sampleRateHz: 44_100, bitsPerChannel: 16, channels: 2, isFloat: false)
private let int32 = SignalFormat(
    formatID: "lpcm", sampleRateHz: 44_100, bitsPerChannel: 32, channels: 2, isFloat: false)

private func path(_ state: DeviceState, gain: Double = 1, playing: Bool = true) -> SignalPath {
    SignalPath(
        track: playing
            ? TrackSignal(
                file: flac, decoded: int32, isConverted: false,
                channelOrderAssumed: false) : nil,
        sink: .device(DeviceSink(name: "ADI-2 DAC", uid: "ADI-2", state: state, gain: gain)))
}

private func device(rate: Double = 44_100, volumes: [VolumeControl] = []) -> DeviceState {
    .connected(
        DeviceSignal(
            nominalSampleRateHz: rate, physical: int32, isMixable: false, hogMode: .thisProcess,
            volumes: volumes, formats: formats))
}

private let formats = DeviceFormats(
    sampleRatesHz: [44_100...44_100, 48_000...48_000, 88_200...192_000],
    formats: [16, 24, 24].map { bits in
        PhysicalFormat(
            formatID: "lpcm", sampleRateHz: 44_100...192_000, bitsPerChannel: bits, channels: 2,
            isFloat: false, isMixable: true)
    })

@Test func aBitPerfectPathListsEachStage() {
    let lines = signalPathLines(path(device(volumes: [.init(.virtualMain, scalar: 1)])))
    #expect(lines.badge == "Bit-perfect")
    #expect(lines.tone == .bitPerfect)
    #expect(lines.detail == "")
    #expect(
        lines.rows == [
            .init(label: "File", value: "FLAC 16-bit int, 44.1 kHz, 2 ch"),
            .init(label: "Decoder", value: "PCM 32-bit int, 44.1 kHz, 2 ch"),
            .init(
                label: "Device",
                value: "ADI-2 DAC at 44.1 kHz: PCM 32-bit int, 44.1 kHz, 2 ch, non-mixable"),
            .init(
                label: "Takes", value: "44.1, 48, 88.2–192 kHz; 2 ch 16-bit int, 2 ch 24-bit int"),
            .init(label: "Hog mode", value: "held by this app"),
            .init(label: "Volume", value: "system unity; digital unity"),
        ])
}

@Test func eachChangeIsNamedInTheVerdict() {
    let lines = signalPathLines(
        path(device(rate: 48_000, volumes: [.init(.channel(1), scalar: 0.99999)]), gain: 0.5))
    #expect(lines.badge == "Not bit-perfect")
    #expect(lines.tone == .changed)
    #expect(
        lines.detail
            == "The digital volume is at -6.0 dB; the device runs at 48 kHz, so macOS resamples"
            + " from 44.1 kHz; the device's channel 1 volume is at 99.9%")
    #expect(lines.rows.last == .init(label: "Volume", value: "channel 1 99.9%; digital -6.0 dB"))
}

@Test func aSharedDeviceIsNotGuaranteedBitPerfect() {
    let shared = DeviceState.connected(
        DeviceSignal(
            nominalSampleRateHz: 44_100, physical: int32, isMixable: true, hogMode: .free,
            volumes: [], formats: formats))
    let lines = signalPathLines(path(shared))
    #expect(lines.badge == "Not guaranteed bit-perfect")
    #expect(lines.tone == .changed)
    #expect(signalPathLines(path(shared, gain: 0.5)).badge == "Not bit-perfect")
}

@Test func noOutputNothingPlayingAndAMissingDeviceSaySo() {
    #expect(
        signalPathLines(nil)
            == .init(badge: "No output device", tone: .neutral, detail: "", rows: []))
    let idle = signalPathLines(path(device(), playing: false))
    #expect(idle.badge == "Nothing playing")
    #expect(idle.tone == .neutral)
    #expect(idle.rows.map(\.label) == ["Device", "Takes", "Hog mode", "Volume"])
    let missing = signalPathLines(path(.notConnected))
    #expect(missing.badge == "Not bit-perfect")
    #expect(missing.detail == "The device isn't connected")
    #expect(missing.rows.last == .init(label: "Device", value: "ADI-2 DAC, not connected"))
}

private func rendererPath(_ gapless: RendererGapless, receiver: Bool, playing: Bool = true)
    -> SignalPath
{
    SignalPath(
        track: playing
            ? TrackSignal(
                file: flac, decoded: flac, isConverted: false,
                channelOrderAssumed: false) : nil,
        sink: .renderer(
            RendererSink(
                name: "Denon AVR-X1800H", address: "192.0.2.45",
                contentType: playing ? "audio/flac" : nil, gapless: gapless,
                volumeIsReceivers: receiver)))
}

@Test func aRendererPathSaysTheBytesGoUnchangedAndCantBeChecked() {
    let lines = signalPathLines(rendererPath(.nextURI, receiver: true))
    #expect(lines.badge == "Can't be checked")
    #expect(lines.tone == .neutral)
    #expect(lines.detail == "Sent unchanged to a network renderer, which decodes it")
    #expect(
        lines.rows == [
            .init(label: "File", value: "FLAC 16-bit int, 44.1 kHz, 2 ch"),
            .init(label: "Renderer", value: "Denon AVR-X1800H at 192.0.2.45"),
            .init(label: "Sent", value: "the file's own bytes over HTTP, as audio/flac"),
            .init(label: "Decoder", value: "the renderer's own"),
            .init(label: "Gapless", value: "yes, the next track is handed over while one plays"),
            .init(
                label: "Volume", value: "the receiver's own, set with the Receiver volume commands"),
        ])
    let other = signalPathLines(
        rendererPath(.afterStop("its AVTransport has no X"), receiver: false, playing: false))
    #expect(other.badge == "Nothing playing")
    #expect(other.rows.first == .init(label: "Renderer", value: "Denon AVR-X1800H at 192.0.2.45"))
    #expect(other.rows.contains(.init(label: "Sent", value: "nothing loaded")))
    #expect(
        other.rows.contains(
            .init(
                label: "Gapless",
                value: "no, each track starts after the last stops: its AVTransport has no X")))
    #expect(
        other.rows.last == .init(label: "Volume", value: "the renderer's own; the app sends none"))
}

@Test func theStagesSplitIntoTwoColumnsWithTheFileOnTheLeft() {
    let playing = signalPathLines(path(device()))
    #expect(
        playing.columns.map { $0.map(\.label) } == [
            ["File", "Decoder", "Device"], ["Takes", "Hog mode", "Volume"],
        ])
    let missing = signalPathLines(path(.notConnected))
    #expect(missing.columns.map { $0.map(\.label) } == [["File", "Decoder"], ["Device"]])
    #expect(signalPathLines(nil).columns.isEmpty)
}

@MainActor @Test func thePanelShowsOnlyTheRowsOfTheLatestPathInTwoColumns() {
    let panel = SignalPathPanel()
    panel.show(path(device()))
    panel.show(rendererPath(.nextURI, receiver: true))
    let shown = panel.grids.map { grid in
        grid.subviews.compactMap { ($0 as? NSTextField)?.stringValue }
    }
    #expect(shown.map(\.count) == [6, 6])
    #expect(shown[0].contains("Renderer") && shown[1].contains("Gapless"))
    #expect(!shown.joined().contains("Hog mode"))
    let stack = panel.view as? NSStackView
    let columns = stack?.arrangedSubviews.last as? NSStackView
    #expect(columns?.arrangedSubviews.map(\.subviews) == panel.grids.map { [$0] })
    #expect(columns?.subviews.count == 2)
    #expect(stack?.alignment == .leading)
}

@MainActor @Test func theBadgeAndThreeLinesOfStagesFitTheMinimumWindowWidth() {
    let panel = SignalPathPanel()
    panel.show(path(device()))
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 720, height: 100), styleMask: [.titled],
        backing: .buffered, defer: false)
    window.contentView = panel.view
    panel.view.layoutSubtreeIfNeeded()
    let line = NSTextField(labelWithString: "File")
    line.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    // The verdict and six stages one per line would take seven lines before any spacing.
    #expect(panel.view.fittingSize.height < line.fittingSize.height * 6)
}

@MainActor @Test func theBadgeShowsItsWholeLabel() {
    let panel = SignalPathPanel()
    panel.show(nil)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 720, height: 100), styleMask: [.titled],
        backing: .buffered, defer: false)
    window.contentView = panel.view
    panel.view.layoutSubtreeIfNeeded()
    let label = panel.badgeLabel.convert(panel.badgeLabel.bounds, to: panel.view)
    #expect(label.height >= panel.badgeLabel.fittingSize.height)
    #expect(panel.badge.convert(panel.badge.bounds, to: panel.view).contains(label))
    #expect(panel.view.bounds.contains(label))
}

@Test func dsdShowsItsRateAndDoPWithTheDigitalVolumeBypassed() {
    let dsd = SignalFormat(
        formatID: dsdFormatID, sampleRateHz: 5_644_800, bitsPerChannel: 1, channels: 2,
        isFloat: false)
    let dop = SignalFormat(
        formatID: dopFormatID, sampleRateHz: 352_800, bitsPerChannel: 24, channels: 2,
        isFloat: false)
    let carrier = SignalFormat(
        formatID: "lpcm", sampleRateHz: 352_800, bitsPerChannel: 32, channels: 2, isFloat: false)
    let state = DeviceState.connected(
        DeviceSignal(
            nominalSampleRateHz: 352_800, physical: carrier, isMixable: false,
            hogMode: .thisProcess, volumes: [], formats: formats))
    let lines = signalPathLines(
        SignalPath(
            track: TrackSignal(
                file: dsd, decoded: dop, isConverted: false,
                channelOrderAssumed: false),
            sink: .device(DeviceSink(name: "ADI-2 DAC", uid: "ADI-2", state: state, gain: 1))))
    #expect(lines.badge == "Bit-perfect")
    #expect(lines.rows[0] == .init(label: "File", value: "DSD128, 2 ch"))
    #expect(lines.rows[1] == .init(label: "Decoder", value: "DoP at 352.8 kHz, 2 ch"))
    #expect(
        lines.rows[2]
            == .init(
                label: "Device",
                value: "ADI-2 DAC at 352.8 kHz: PCM 32-bit int, 352.8 kHz, 2 ch, non-mixable"))
    #expect(
        lines.rows.last
            == .init(label: "Volume", value: "no device controls; digital bypassed for DoP"))
}

@Test func aConvertedTrackIsBadgedConvertedWithWhatTo() {
    let float48 = SignalFormat(
        formatID: "lpcm", sampleRateHz: 48_000, bitsPerChannel: 32, channels: 2, isFloat: true)
    let lines = signalPathLines(
        SignalPath(
            track: TrackSignal(
                file: flac, decoded: float48, isConverted: true,
                channelOrderAssumed: false),
            sink: .device(
                DeviceSink(
                    name: "AirPods", uid: "AirPods",
                    state: .connected(
                        DeviceSignal(
                            nominalSampleRateHz: 48_000, physical: float48, isMixable: true,
                            hogMode: .thisProcess, volumes: [], formats: formats)),
                    gain: 1))))
    #expect(lines.badge == "Converted")
    #expect(lines.tone == .changed)
    #expect(
        lines.detail
            == "The device can't take the file's format, so it's converted to PCM 32-bit float,"
            + " 48 kHz, 2 ch; the decoder resamples 44.1 kHz to 48 kHz; the format is mixable,"
            + " so macOS mixes other apps' sound in")
}

@Test func aDownmixInAnAssumedChannelOrderSaysSo() {
    let wav = SignalFormat(
        formatID: "lpcm", sampleRateHz: 48_000, bitsPerChannel: 24, channels: 6, isFloat: false)
    let float48 = SignalFormat(
        formatID: "lpcm", sampleRateHz: 48_000, bitsPerChannel: 32, channels: 2, isFloat: true)
    let lines = signalPathLines(
        SignalPath(
            track: TrackSignal(
                file: wav, decoded: float48, isConverted: true, channelOrderAssumed: true),
            sink: .device(
                DeviceSink(
                    name: "AirPods", uid: "AirPods",
                    state: .connected(
                        DeviceSignal(
                            nominalSampleRateHz: 48_000, physical: float48, isMixable: false,
                            hogMode: .thisProcess, volumes: [], formats: formats)),
                    gain: 1))))
    #expect(
        lines.rows[1]
            == .init(
                label: "Decoder",
                value: "PCM 32-bit float, 48 kHz, 2 ch, downmixed 6→2 channels, channel order"
                    + " assumed"))
    #expect(
        lines.detail.contains(
            "the decoder downmixed 6→2 channels; the file doesn't name its channels, so the"
                + " downmix assumes the WAV default order"))
}
