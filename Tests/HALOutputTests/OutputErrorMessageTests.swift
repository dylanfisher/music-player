import CoreAudio
import Foundation
import Testing

@testable import Fixtures
@testable import HALOutput
@testable import Playback

/// One of each case of every error the device output reports, so a case added without a
/// message for people shows here.
private let errors: [any PlaybackFailure] =
    [
        DeviceOutputError.outOfMemory, .noVolumeForFormat("'lpcm' 2 ch 32-bit int"),
        .endedEarly(atSeconds: 61.5, ofSeconds: 259),
        .noDoPLayout(
            SignalFormat(
                formatID: "lpcm", sampleRateHz: 176_400, bitsPerChannel: 16, channels: 2,
                isFloat: false)),
        .noChannelMix(fromChannels: 8, toChannels: 6),
    ]
    + [DoPRefusal.noRate, .noFormat, .noHogMode].map {
        DeviceOutputError.cannotPlayDSD(
            device: "ADI-2 DAC", deviceUID: "ADI-2", dsdRateHz: 2_822_400, carrierRateHz: 176_400,
            $0)
    }
    + [
        HALDeviceError.hogModeHeld(by: 4242, app: nil), .hogModeHeld(by: 4242, app: "Audirvana"),
        .noOutputStream,
        .noBitPerfectFormat(sampleRateHz: 96_000, channels: 2, minimumBits: 24), .noPCMFormat,
        .didNotSettle("96 kHz"),
    ] as [any PlaybackFailure]
    + [
        HALDeviceProviderError.noDefaultOutput,
        HALError(selector: kAudioDevicePropertyNominalSampleRate, status: -50),
    ] as [any PlaybackFailure]
    + [
        "ExtAudioFileOpenURL", "ExtAudioFileRead", "AudioConverterNew", "AudioDeviceStart",
    ].map { OSStatusError(operation: $0, status: 1_954_115_647) }

@Test func everyOutputErrorHasAPlainMessage() {
    for error in errors {
        #expect(readsAsPlainText(error.userMessage), "\(error): \(error.userMessage)")
    }
    // The check catches what the status bar used to show.
    #expect(!readsAsPlainText("\(OSStatusError(operation: "ExtAudioFileOpenURL", status: -50))"))
    #expect(!readsAsPlainText("\(HALError(selector: kAudioDevicePropertyHogMode, status: 560))"))
}

/// Only hog mode being off has a fix: the app can't give a device a rate or a format.
@Test func theHogModeRefusalSaysWhyAndCarriesItsFix() {
    let refusals = [DoPRefusal.noHogMode, .noRate, .noFormat].map {
        DeviceOutputError.cannotPlayDSD(
            device: "ADI-2 DAC", deviceUID: "ADI-2", dsdRateHz: 2_822_400, carrierRateHz: 176_400,
            $0)
    }
    #expect(
        refusals[0].userMessage
            == "DoP needs exclusive access, and hog mode is off for this device")
    #expect(refusals.map(\.fix) == [.turnOnHogMode(deviceUID: "ADI-2"), nil, nil])
    #expect(errors.filter { $0.fix != nil }.count == 1)
}

/// Hog mode held by another app names it, and has no fix: only that app can let go.
@Test func hogModeHeldNamesTheAppHoldingIt() {
    let held = HALDeviceError.held(by: getpid())
    let name = ProcessInfo.processInfo.processName
    #expect(held.userMessage.hasPrefix(String(name.prefix(16))), "\(held.userMessage)")
    #expect(held.userMessage.hasSuffix(" has the device to itself, so nothing else can play to it"))
    #expect(held.fix == nil)
    #expect(HALDeviceError.hogModeHeld(by: 4242, app: nil).userMessage.hasPrefix("another app "))
}
