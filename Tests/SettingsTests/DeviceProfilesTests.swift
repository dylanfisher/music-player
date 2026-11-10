import Foundation
import Playback
import Testing

@testable import Settings

private let config = OutputConfig(hogMode: true, digitalVolume: false)

private let reported = DeviceFormats(
    sampleRatesHz: [44_100...44_100, 48_000...48_000],
    formats: [
        PhysicalFormat(
            formatID: linearPCMFormatID, sampleRateHz: 44_100...48_000, bitsPerChannel: 24,
            channels: 2, isFloat: false, isMixable: true)
    ])

/// The DAC and the built-in output with different settings, the DAC used last.
private let twoDevices = DeviceProfiles(profiles: [
    DeviceProfile(
        uid: "DAC", hogMode: true, digitalVolume: false, volumeDecibels: 0, formats: reported),
    DeviceProfile(
        uid: "BuiltIn", hogMode: false, digitalVolume: true, volumeDecibels: -12, formats: nil),
])

@Test func aFirstSeenDeviceStartsFromTheConfigAtFullVolume() {
    let profile = twoDevices.profile(
        for: "USB", config: OutputConfig(hogMode: false, digitalVolume: true), switched: true,
        typeHogs: nil)
    #expect(
        profile
            == DeviceProfile(
                uid: "USB", hogMode: false, digitalVolume: true, volumeDecibels: 0, formats: nil))
}

@Test func aFirstSeenDeviceHogsOnlyWhenTheConfigAndItsKindBothDo() {
    let hogging = OutputConfig(hogMode: true, digitalVolume: false)
    #expect(
        !twoDevices.profile(for: "Speakers", config: hogging, switched: true, typeHogs: false)
            .hogMode)
    #expect(
        twoDevices.profile(for: "USB", config: hogging, switched: true, typeHogs: true).hogMode)
    #expect(
        twoDevices.profile(for: "Unplugged", config: hogging, switched: true, typeHogs: nil)
            .hogMode)
    // Hog mode is off unless asked for, so a DAC seen first with the setting off doesn't hog.
    #expect(
        !twoDevices.profile(
            for: "USB", config: OutputConfig(hogMode: false, digitalVolume: false),
            switched: true, typeHogs: true
        ).hogMode)
    // A seen device keeps its own, whatever its kind.
    #expect(
        twoDevices.profile(for: "DAC", config: hogging, switched: true, typeHogs: false).hogMode)
}

@Test func aSeenDevicesKindIsNeverRead() {
    var reads = 0
    func kind() -> Bool? {
        reads += 1
        return false
    }
    _ = twoDevices.profile(for: "DAC", config: config, switched: true, typeHogs: kind())
    _ = twoDevices.profile(for: "DAC", config: config, switched: false, typeHogs: kind())
    #expect(reads == 0)
    _ = twoDevices.profile(for: "USB", config: config, switched: true, typeHogs: kind())
    #expect(reads == 1)
}

@Test func switchingToASeenDeviceKeepsItsOwnSettings() {
    let profile = twoDevices.profile(for: "BuiltIn", config: config, switched: true, typeHogs: nil)
    #expect(profile == twoDevices.profiles[1])
}

@Test func aConfigEditMeetsOnlyTheDeviceInUse() {
    let edited = OutputConfig(hogMode: false, digitalVolume: true)
    var profile = twoDevices.profile(for: "DAC", config: edited, switched: false, typeHogs: nil)
    #expect(profile.hogMode == false && profile.digitalVolume == true)
    #expect(profile.volumeDecibels == 0 && profile.formats == reported)
    profile.volumeDecibels = -6
    let profiles = twoDevices.using(profile)
    #expect(profiles.profiles.map(\.uid) == ["DAC", "BuiltIn"])
    #expect(profiles.profiles[0] == profile)
    // The other device keeps its own, and switching to it doesn't take the edit.
    #expect(
        profiles.profile(for: "BuiltIn", config: edited, switched: true, typeHogs: nil)
            == twoDevices.profiles[1])
    // A device not seen yet starts from the edit.
    #expect(
        profiles.profile(for: "USB", config: edited, switched: true, typeHogs: nil).hogMode == false
    )
}

@Test func usingADeviceMovesItFirstAndEvictsTheLeastRecentlyUsedPastTheCap() {
    var profiles = DeviceProfiles(profiles: [])
    for index in 0..<DeviceProfiles.capacity {
        profiles = profiles.using(
            profiles.profile(for: "d\(index)", config: config, switched: true, typeHogs: nil))
    }
    #expect(profiles.profiles.count == DeviceProfiles.capacity)
    // The oldest used again, then one more: the second oldest goes.
    profiles = profiles.using(
        profiles.profile(for: "d0", config: config, switched: true, typeHogs: nil))
    profiles = profiles.using(
        profiles.profile(for: "new", config: config, switched: true, typeHogs: nil))
    #expect(profiles.profiles.count == DeviceProfiles.capacity)
    #expect(profiles.profiles.prefix(2).map(\.uid) == ["new", "d0"])
    #expect(!profiles.profiles.contains { $0.uid == "d1" })
    #expect(profiles.profiles.last?.uid == "d2")
    #expect(profiles.problem() == nil)
}

@Test func reportedFormatsAreRecordedInPlaceOnlyWhenTheyChange() throws {
    #expect(twoDevices.reporting(reported, for: "DAC") == nil)
    #expect(twoDevices.reporting(reported, for: "USB") == nil)
    let profiles = try #require(twoDevices.reporting(reported, for: "BuiltIn"))
    #expect(profiles.profiles.map(\.uid) == ["DAC", "BuiltIn"])
    #expect(profiles.profiles[1].formats == reported)

    let many = DeviceFormats(
        sampleRatesHz: (0..<100).map { Double($0 * 1000)...Double($0 * 1000) },
        formats: Array(repeating: reported.formats[0], count: 100))
    let capped = try #require(twoDevices.reporting(many, for: "DAC"))
    #expect(capped.profiles[0].formats?.sampleRatesHz.count == DeviceProfiles.formatCapacity)
    #expect(capped.profiles[0].formats?.formats.count == DeviceProfiles.formatCapacity)
    #expect(capped.problem() == nil)
}

@Test func profilesSurviveTheStateFileAndBadOnesAreRefused() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("profiles-\(UUID().uuidString)/state.json")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let state = try StateStore(AppState(), fileURL: url)
    try state.set(\.deviceProfiles, to: twoDevices)
    let reread = try StateStore(AppState(), fileURL: url)
    #expect(reread.discardReason == nil)
    #expect(reread[\.deviceProfiles] == twoDevices)

    var twice = twoDevices
    twice.profiles.append(twoDevices.profiles[0])
    var loud = twoDevices
    loud.profiles[1].volumeDecibels = 3
    for bad in [twice, loud] {
        #expect(throws: SettingsError.self) { try state.set(\.deviceProfiles, to: bad) }
    }
}

@Test(arguments: [
    #"[{"uid": "DAC", "hogMode": true, "digitalVolume": false, "volumeDecibels": 0, "x": 1}]"#,
    #"[{"uid": "DAC", "hogMode": true, "digitalVolume": false, "volumeDecibels": 0,"#
        + #" "formats": {"sampleRatesHz": [], "formats": [], "x": 1}}]"#,
    #"[{"uid": "DAC", "hogMode": true, "digitalVolume": false, "volumeDecibels": 0,"#
        + #" "formats": {"sampleRatesHz": [[44100, 44100]], "formats": [{"formatID": "lpcm","#
        + #" "sampleRateHz": [44100, 48000], "bitsPerChannel": 24, "channels": 2,"#
        + #" "isFloat": false, "isMixable": true, "x": 1}]}}]"#,
    #"[{"uid": "DAC", "hogMode": true, "digitalVolume": false}]"#,
])
func aStoredProfileWithAnUnknownOrMissingKeyAtAnyLevelIsDiscarded(_ json: String) throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("profiles-\(UUID().uuidString)/state.json")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"output.profiles": \#(json)}"#.utf8).write(to: url)
    let state = try StateStore(AppState(), fileURL: url)
    #expect(state.discardReason?.contains("Device Profiles") == true)
    #expect(state[\.deviceProfiles] == DeviceProfiles(profiles: []))
}

@Test func aStoredProfileWithEveryLevelFilledInReads() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("profiles-\(UUID().uuidString)/state.json")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let json =
        #"{"output.profiles": [{"uid": "DAC", "hogMode": true, "digitalVolume": false,"#
        + #" "volumeDecibels": 0, "formats": {"sampleRatesHz": [[44100, 44100], [48000, 48000]],"#
        + #" "formats": [{"formatID": "lpcm", "sampleRateHz": [44100, 48000],"#
        + #" "bitsPerChannel": 24, "channels": 2, "isFloat": false, "isMixable": true}]}}]}"#
    try Data(json.utf8).write(to: url)
    let state = try StateStore(AppState(), fileURL: url)
    #expect(state.discardReason == nil)
    #expect(state[\.deviceProfiles].profiles == [twoDevices.profiles[0]])
}
