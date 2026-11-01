import Testing

@testable import Playback

private func pcm(_ hertz: Double, bits: UInt32, channels: UInt32 = 2, float: Bool = false)
    -> SignalFormat
{
    SignalFormat(
        formatID: "lpcm", sampleRateHz: hertz, bitsPerChannel: bits, channels: channels,
        isFloat: float)
}

private let flac24 = SignalFormat(
    formatID: "flac", sampleRateHz: 96_000, bitsPerChannel: 24, channels: 2, isFloat: false)
private let decoded = pcm(96_000, bits: 32)

private func device(
    rate: Double = 96_000, physical: SignalFormat = pcm(96_000, bits: 32), mixable: Bool = false,
    hog: HogMode = .thisProcess, volumes: [VolumeControl] = []
) -> DeviceState {
    .connected(
        DeviceSignal(
            nominalSampleRateHz: rate, physical: physical, isMixable: mixable, hogMode: hog,
            volumes: volumes))
}

private func verdict(
    file: SignalFormat = flac24, decoded: SignalFormat = decoded, state: DeviceState = device(),
    gain: Double = 1
) -> SignalVerdict {
    signalVerdict(
        SignalPath(
            track: TrackSignal(file: file, decoded: decoded),
            sink: .device(DeviceSink(name: "DAC", state: state, gain: gain))))
}

@Test func nothingLoadedIsIdle() {
    let path = SignalPath(
        track: nil, sink: .device(DeviceSink(name: "DAC", state: .notConnected, gain: 1)))
    #expect(signalVerdict(path) == .idle)
}

@Test func matchingRateDepthAndChannelsInHogModeAtUnityIsBitPerfect() {
    #expect(verdict() == .bitPerfect)
    // A unity volume control is no change, and 16 bits pad exactly into 24.
    #expect(
        verdict(
            file: pcm(96_000, bits: 16),
            state: device(physical: pcm(96_000, bits: 24), volumes: [.init(.main, scalar: 1)]))
            == .bitPerfect)
}

@Test func aDeviceAtAnotherRateResamples() {
    #expect(
        verdict(state: device(rate: 48_000))
            == .changed([.deviceResamples(fromHz: 96_000, toHz: 48_000)]))
}

@Test func aDecoderThatResamplesOrRemixesIsNamed() {
    #expect(
        verdict(decoded: pcm(48_000, bits: 32), state: device(rate: 48_000))
            == .changed([.decoderResamples(fromHz: 96_000, toHz: 48_000)]))
    #expect(
        verdict(decoded: pcm(96_000, bits: 32, channels: 1))
            == .changed([
                .decoderRemixes(fromChannels: 2, toChannels: 1),
                .deviceRemixes(fromChannels: 1, toChannels: 2),
            ]))
}

@Test func aDeviceWithOtherChannelsRemixes() {
    #expect(
        verdict(state: device(physical: pcm(96_000, bits: 32, channels: 8)))
            == .changed([.deviceRemixes(fromChannels: 2, toChannels: 8)]))
}

@Test func aNarrowerOrFloatFormatLosesPrecision() {
    let narrow = pcm(96_000, bits: 16)
    #expect(verdict(state: device(physical: narrow)) == .changed([.deviceLosesPrecision(narrow)]))
    let float = pcm(96_000, bits: 32, float: true)
    #expect(verdict(decoded: float, state: device(physical: float)) == .bitPerfect)
    let wide = pcm(96_000, bits: 32)
    #expect(
        verdict(file: wide, decoded: float, state: device(physical: float))
            == .changed([.decoderLosesPrecision(float), .deviceLosesPrecision(float)]))
    let floatFile = pcm(96_000, bits: 32, float: true)
    #expect(
        verdict(file: floatFile)
            == .changed([.decoderLosesPrecision(decoded), .deviceLosesPrecision(decoded)]))
}

@Test func aLossyFileIsJudgedFromWhatItDecodesTo() {
    let mp3 = SignalFormat(
        formatID: ".mp3", sampleRateHz: 44_100, bitsPerChannel: nil, channels: 2, isFloat: false)
    let float = pcm(44_100, bits: 32, float: true)
    let int = pcm(44_100, bits: 32)
    #expect(
        verdict(file: mp3, decoded: int, state: device(rate: 44_100, physical: int)) == .bitPerfect)
    #expect(
        verdict(file: mp3, decoded: float, state: device(rate: 44_100, physical: int))
            == .changed([.deviceLosesPrecision(int)]))
}

@Test func aMixableFormatAndHogModeNotHeldAreNamed() {
    #expect(
        verdict(state: device(mixable: true, hog: .free))
            == .changed([.mixableFormat, .hogModeFree]))
    #expect(
        verdict(state: device(hog: .otherProcess(pid: 42))) == .changed([.hogModeHeld(byPID: 42)]))
}

@Test func volumeBelowUnityIsNamed() {
    let volumes: [VolumeControl] = [
        .init(.virtualMain, scalar: 0.9), .init(.main, scalar: 1), .init(.channel(2), scalar: 0.5),
    ]
    #expect(verdict(state: device(volumes: volumes)) == .changed([.deviceVolume(volumes[2])]))
    #expect(verdict(gain: 0.5) == .changed([.digitalVolume(gain: 0.5)]))
    #expect(verdict(gain: 0.999_999_9) == .changed([.digitalVolume(gain: 0.999_999_9)]))
}

@Test func aMissingOrUnreadableDeviceIsNamed() {
    #expect(verdict(state: .notConnected) == .changed([.deviceNotConnected]))
    #expect(verdict(state: .unreadable("gone")) == .changed([.deviceUnreadable("gone")]))
    #expect(
        verdict(state: .notConnected, gain: 0.5)
            == .changed([.digitalVolume(gain: 0.5), .deviceNotConnected]))
}
