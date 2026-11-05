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

@Test func aBitPerfectPathShowsTheFileThenTheDevice() {
    let lines = signalPathLines(path(device(volumes: [.init(.virtualMain, scalar: 1)])))
    #expect(lines.badge == "Bit-perfect")
    #expect(lines.tone == .bitPerfect)
    #expect(lines.detail == "")
    // The decoder changes nothing, so it isn't a stage of its own.
    #expect(
        lines.stages == [
            .init(title: "File", value: "44.1 kHz · 16-bit", note: "FLAC · stereo", changes: false),
            .init(
                title: "ADI-2 DAC", value: "44.1 kHz · 32-bit", note: "Exclusive", changes: false),
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
    #expect(
        lines.stages.last
            == .init(
                title: "ADI-2 DAC", value: "48 kHz · 32-bit",
                note: "Exclusive · volume -6.0 dB · device volume 99.9%", changes: true))
}

@Test func aSharedDeviceIsNotGuaranteedBitPerfect() {
    let shared = DeviceState.connected(
        DeviceSignal(
            nominalSampleRateHz: 44_100, physical: int32, isMixable: true, hogMode: .free,
            volumes: [], formats: formats))
    let lines = signalPathLines(path(shared))
    #expect(lines.badge == "Not guaranteed bit-perfect")
    #expect(lines.tone == .changed)
    #expect(lines.stages.last?.note == "Shared with other apps")
    #expect(signalPathLines(path(shared, gain: 0.5)).badge == "Not bit-perfect")
}

@Test func anotherAppHoldingTheDeviceIsNamedWithoutItsProcess() {
    let held = DeviceState.connected(
        DeviceSignal(
            nominalSampleRateHz: 44_100, physical: int32, isMixable: false,
            hogMode: .otherProcess(pid: 4321), volumes: [], formats: formats))
    let lines = signalPathLines(path(held))
    #expect(lines.badge == "Not bit-perfect")
    #expect(lines.detail == "Another app holds the device for itself")
    #expect(lines.stages.last?.note == "Held by another app")
}

@Test func noOutputNothingPlayingAndAMissingDeviceSaySo() {
    #expect(
        signalPathLines(nil)
            == .init(badge: "No output device", tone: .neutral, detail: "", stages: []))
    let idle = signalPathLines(path(device(), playing: false))
    #expect(idle.badge == "Nothing playing")
    #expect(idle.tone == .neutral)
    #expect(idle.stages.map(\.title) == ["ADI-2 DAC"])
    let missing = signalPathLines(path(.notConnected))
    #expect(missing.badge == "Not bit-perfect")
    #expect(missing.detail == "The device isn't connected")
    #expect(
        missing.stages.last
            == .init(title: "ADI-2 DAC", value: "Not connected", note: "", changes: true))
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
        lines.stages == [
            .init(title: "File", value: "44.1 kHz · 16-bit", note: "FLAC · stereo", changes: false),
            .init(
                title: "Denon AVR-X1800H", value: "Plays the file itself",
                note: "Gapless · receiver's volume", changes: false),
        ])
    let other = signalPathLines(
        rendererPath(.afterStop("its AVTransport has no X"), receiver: false, playing: false))
    #expect(other.badge == "Nothing playing")
    #expect(
        other.stages == [
            .init(
                title: "Denon AVR-X1800H", value: "Nothing loaded",
                note: "Not gapless · its own volume", changes: false)
        ])
}

/// The shown text of each of the panel's stage boxes, in order.
@MainActor private func shownStages(_ panel: SignalPathPanel) -> [[String]] {
    panel.stages.arrangedSubviews.compactMap { view in
        let fields = (view.subviews.first as? NSStackView)?.arrangedSubviews
            .compactMap { $0 as? NSTextField }
        return fields.map { $0.filter { !$0.isHidden }.map(\.stringValue) }
    }
}

@MainActor @Test func thePanelShowsOnlyTheStagesOfTheLatestPathJoinedByArrows() {
    let panel = SignalPathPanel()
    panel.show(path(device()))
    panel.show(rendererPath(.nextURI, receiver: true))
    #expect(
        shownStages(panel) == [
            ["File", "44.1 kHz · 16-bit", "FLAC · stereo"],
            ["Denon AVR-X1800H", "Plays the file itself", "Gapless · receiver's volume"],
        ])
    #expect(panel.stages.arrangedSubviews.count == 3)
    #expect(panel.stages.arrangedSubviews[1] is NSImageView)
    panel.show(nil)
    #expect(panel.stages.arrangedSubviews.isEmpty)
}

@MainActor @Test func theStagesFitTheMinimumWindowWidth() {
    let panel = SignalPathPanel()
    panel.show(
        SignalPath(
            track: TrackSignal(
                file: flac, decoded: int32, isConverted: false, channelOrderAssumed: false),
            sink: .device(
                DeviceSink(
                    name: "ADI-2 DAC", uid: "ADI-2",
                    state: device(rate: 48_000, volumes: [.init(.channel(1), scalar: 0.5)]),
                    gain: 0.5))))
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 720, height: 100), styleMask: [.titled],
        backing: .buffered, defer: false)
    window.contentView = panel.view
    panel.view.layoutSubtreeIfNeeded()
    for box in panel.stages.arrangedSubviews {
        #expect(panel.view.bounds.contains(box.convert(box.bounds, to: panel.view)))
    }
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

@Test func dsdShowsItsRateAndDoP() {
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
    #expect(
        lines.stages == [
            .init(title: "File", value: "DSD128", note: "DSD · stereo", changes: false),
            .init(
                title: "ADI-2 DAC", value: "352.8 kHz · 32-bit", note: "DoP · exclusive",
                changes: false),
        ])
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
            == "The device can't take the file's format, so it's converted to 48 kHz · 32-bit"
            + " float; the decoder resamples 44.1 kHz to 48 kHz; other apps' sound can be mixed"
            + " in")
    #expect(
        lines.stages[1]
            == .init(
                title: "Converted", value: "48 kHz · 32-bit float", note: "Stereo", changes: true)
    )
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
    #expect(lines.stages[0].note == "PCM · 6 channels")
    #expect(
        lines.stages[1]
            == .init(
                title: "Converted", value: "48 kHz · 32-bit float",
                note: "Stereo · downmixed from 6", changes: true))
    #expect(
        lines.detail.contains(
            "the decoder downmixes 6 channels to 2; the file doesn't name its channels, so the"
                + " downmix assumes the WAV default order"))
}
