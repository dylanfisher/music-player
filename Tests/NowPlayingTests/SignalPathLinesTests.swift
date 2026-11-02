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
        track: playing ? TrackSignal(file: flac, decoded: int32) : nil,
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
    #expect(lines.verdict == "Bit-perfect")
    #expect(lines.isBitPerfect)
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
    #expect(!lines.isBitPerfect)
    #expect(
        lines.verdict
            == "Not bit-perfect: the digital volume is at -6.0 dB; the device runs at 48 kHz, so"
            + " macOS resamples from 44.1 kHz; the device's channel 1 volume is at 99.9%")
    #expect(lines.rows.last == .init(label: "Volume", value: "channel 1 99.9%; digital -6.0 dB"))
}

@Test func noOutputNothingPlayingAndAMissingDeviceSaySo() {
    #expect(
        signalPathLines(nil) == .init(verdict: "No output device", isBitPerfect: false, rows: []))
    let idle = signalPathLines(path(device(), playing: false))
    #expect(idle.verdict == "Nothing playing")
    #expect(idle.rows.map(\.label) == ["Device", "Takes", "Hog mode", "Volume"])
    let missing = signalPathLines(path(.notConnected))
    #expect(missing.verdict == "Not bit-perfect: the device isn't connected")
    #expect(missing.rows.last == .init(label: "Device", value: "ADI-2 DAC, not connected"))
}

private func rendererPath(_ gapless: RendererGapless, receiver: Bool, playing: Bool = true)
    -> SignalPath
{
    SignalPath(
        track: playing ? TrackSignal(file: flac, decoded: flac) : nil,
        sink: .renderer(
            RendererSink(
                name: "Denon AVR-X1800H", address: "192.0.2.45",
                contentType: playing ? "audio/flac" : nil, gapless: gapless,
                volumeIsReceivers: receiver)))
}

@Test func aRendererPathSaysTheBytesGoUnchangedAndCantBeChecked() {
    let lines = signalPathLines(rendererPath(.nextURI, receiver: true))
    #expect(!lines.isBitPerfect)
    #expect(
        lines.verdict
            == "Sent unchanged to a network renderer, which decodes it: bit-perfect can't be"
            + " checked from this Mac")
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
    #expect(other.verdict == "Nothing playing")
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

@MainActor @Test func thePanelShowsOnlyTheRowsOfTheLatestPathLeftAligned() {
    let panel = SignalPathPanel()
    panel.show(path(device()))
    panel.show(rendererPath(.nextURI, receiver: true))
    let shown = panel.grid.subviews.compactMap { ($0 as? NSTextField)?.stringValue }
    let expected = signalPathLines(rendererPath(.nextURI, receiver: true)).rows
    #expect(shown.count == expected.count * 2)
    #expect(!shown.contains("Hog mode"))
    #expect(panel.view.subviews.filter { $0 is NSGridView } == [panel.grid])
    #expect((panel.view as? NSStackView)?.alignment == .leading)
}
