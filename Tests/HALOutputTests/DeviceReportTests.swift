import CoreAudio
import Testing

@testable import HALOutput

@Test(arguments: [
    (44_100.0, "44.1"), (96_000.0, "96"), (705_600.0, "705.6"), (768_000.0, "768"),
])
func formatsKilohertz(hertz: Double, expected: String) {
    #expect(kilohertz(hertz) == expected)
}

@Test func rendersFourCharCodes() {
    #expect(fourCharCode(kAudioDeviceTransportTypeUSB) == "usb ")
    #expect(fourCharCode(kAudioFormatLinearPCM) == "lpcm")
    #expect(fourCharCode(UInt32(bitPattern: -50)) == "0xffffffce")
}

@Test func readsPhysicalFormatFlags() {
    var description = AudioStreamBasicDescription()
    description.mFormatID = kAudioFormatLinearPCM
    description.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsNonMixable
    description.mBitsPerChannel = 24
    description.mChannelsPerFrame = 2
    let format = PhysicalFormat(
        AudioStreamRangedDescription(
            mFormat: description,
            mSampleRateRange: AudioValueRange(mMinimum: 44_100, mMaximum: 768_000)))

    #expect(
        format
            == PhysicalFormat(
                formatID: "lpcm", sampleRateHz: 44_100...768_000, bitsPerChannel: 24, channels: 2,
                isFloat: false, isMixable: false))
}

@Test func reportListsFormatsAndHogOwner() {
    let format = PhysicalFormat(
        formatID: "lpcm", sampleRateHz: 192_000...192_000, bitsPerChannel: 32, channels: 2,
        isFloat: false, isMixable: false)
    let device = AudioDevice(
        id: 1, name: "ADI-2 DAC", manufacturer: "RME", uid: "uid-1", transport: "usb ",
        nominalSampleRateHz: 192_000, availableSampleRatesHz: [44_100...44_100, 192_000...192_000],
        outputStreams: [AudioDevice.Stream(id: 2, current: format, available: [format])],
        hogModeOwner: 412)

    let report = deviceReport([device])

    #expect(report.contains("ADI-2 DAC — RME"))
    #expect(report.contains("hog mode: held by pid 412"))
    #expect(report.contains("available rates: 44.1, 192 kHz"))
    #expect(report.contains("'lpcm' 2 ch 32-bit int @ 192 kHz, non-mixable"))
}
