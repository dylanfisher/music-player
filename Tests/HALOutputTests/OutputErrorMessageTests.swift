import CoreAudio
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
            device: "ADI-2 DAC", dsdRateHz: 2_822_400, carrierRateHz: 176_400, $0)
    }
    + [
        HALDeviceError.hogModeHeld(by: 4242), .noOutputStream,
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

@Test func theHogModeRefusalSaysWhyInPlainWords() {
    let refusal = DeviceOutputError.cannotPlayDSD(
        device: "ADI-2 DAC", dsdRateHz: 2_822_400, carrierRateHz: 176_400, .noHogMode)
    #expect(
        refusal.userMessage
            == "ADI-2 DAC can't play DSD64: DoP needs exclusive access, and hog mode is off for"
            + " this device")
}
