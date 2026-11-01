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
        sink: .device(DeviceSink(name: "ADI-2 DAC", state: state, gain: gain)))
}

private func device(rate: Double = 44_100, volumes: [VolumeControl] = []) -> DeviceState {
    .connected(
        DeviceSignal(
            nominalSampleRateHz: rate, physical: int32, isMixable: false, hogMode: .thisProcess,
            volumes: volumes))
}

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
    #expect(idle.rows.map(\.label) == ["Device", "Hog mode", "Volume"])
    let missing = signalPathLines(path(.notConnected))
    #expect(missing.verdict == "Not bit-perfect: the device isn't connected")
    #expect(missing.rows.last == .init(label: "Device", value: "ADI-2 DAC, not connected"))
}
