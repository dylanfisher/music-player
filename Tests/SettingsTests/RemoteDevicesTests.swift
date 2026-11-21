import Foundation
import Testing

@testable import Settings

private let hash = String(repeating: "ab", count: 32)

private func device(_ name: String = "iPhone, Safari", hash: String = hash)
    -> RemoteDevices.Device
{
    RemoteDevices.Device(name: name, tokenHash: hash, pairedSeconds: 10, lastSeenSeconds: 20)
}

@Test func pairedDevicesSurviveAReloadAndRefuseUnknownKeys() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("remote-\(UUID().uuidString)/state.json")
    let state = try StateStore(AppState(), fileURL: url)
    let devices = RemoteDevices(devices: [device()])
    try state.set(\.remoteDevices, to: devices)
    #expect(try StateStore(AppState(), fileURL: url)[\.remoteDevices] == devices)
    let extra =
        #"{"remote.devices": [{"name": "a", "tokenHash": "\#(hash)", "pairedSeconds": 1,"#
        + #" "lastSeenSeconds": 1, "token": "x"}]}"#
    #expect(
        try parse(Data(extra.utf8), path: url.path, settings: keyed(AppState())).dropped != nil)
}

@Test func aDeviceListIsRefusedForABadHashADuplicateOrABadName() {
    #expect(RemoteDevices(devices: [device()]).problem() == nil)
    #expect(RemoteDevices(devices: [device(hash: "AB" + hash.dropFirst(2))]).problem() != nil)
    #expect(RemoteDevices(devices: [device(hash: String(hash.dropFirst()))]).problem() != nil)
    #expect(RemoteDevices(devices: [device(), device("Mac")]).problem() != nil)
    #expect(RemoteDevices(devices: [device("")]).problem() != nil)
    #expect(RemoteDevices(devices: [device("a\u{7}b")]).problem() != nil)
    #expect(RemoteDevices(devices: [device(String(repeating: "x", count: 65))]).problem() != nil)
    let many = (0...RemoteDevices.capacity).map { index in
        device(hash: String(format: "%064x", index))
    }
    #expect(RemoteDevices(devices: many).problem() == "more than 32 devices")
}

@Test func theRemoteIsOffByDefaultOnItsFixedPort() {
    #expect(AppSettings().remoteEnabled.defaultValue == false)
    #expect(AppSettings().remotePort.defaultValue == 47800)
}
