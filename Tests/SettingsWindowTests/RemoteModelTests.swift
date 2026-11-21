import Foundation
import Settings
import Testing

@testable import Remote
@testable import SettingsWindow

/// Controls over a real pairing and registry, with the remote on at `links` unless it's nil.
@MainActor
func remoteControls(
    links: RemoteLinks? = nil, registry: RemoteDeviceRegistry? = nil
) -> RemoteControls {
    RemoteControls(pairing: RemotePairing(), devices: { registry }, links: { links })
}

private let links = RemoteLinks(local: "http://studio.local:47800", lan: "http://10.0.0.2:47800")

@MainActor @Test func whileTheRemoteIsOffNoCodeCanBeShown() {
    let model = RemoteModel(remoteControls())
    model.showCode()
    #expect(model.code == nil && model.pairingLink == nil && model.addresses == nil)
    #expect(!model.canShowCode)
    #expect(model.detail == "Turn on the web remote to pair a phone.")
}

@MainActor @Test func aShownCodeComesWithItsPairingLinkTheAddressesAndItsTimeLeft() throws {
    let model = RemoteModel(remoteControls(links: links))
    #expect(model.code == nil && model.detail == "Show a code to pair a phone.")
    model.showCode()
    let code = try #require(model.code)
    #expect(code.count == 7 && code.dropFirst(3).first == " ")
    #expect(model.pairingLink == "http://studio.local:47800/#pair=" + code.replacing(" ", with: ""))
    #expect(model.addresses == "http://studio.local:47800  or  http://10.0.0.2:47800")
    #expect(model.detail.hasSuffix("It ends in 2:00."))
    #expect(qrImage(try #require(model.pairingLink)) != nil)
}

/// Seconds tests move by hand.
private final class Clock: @unchecked Sendable {
    // Guarded by `lock`.
    private let lock = NSLock()
    private var seconds = 0.0
    var now: Double { lock.withLock { seconds } }
    func advance(_ by: Double) { lock.withLock { seconds += by } }
}

@MainActor @Test func anExpiredCodeSaysWhyAndForgetRemovesTheDevice() throws {
    let clock = Clock()
    let controls = RemoteControls(
        pairing: RemotePairing(now: { clock.now }), devices: { nil }, links: { links })
    let model = RemoteModel(controls)
    model.showCode()
    clock.advance(RemotePairing.lifetimeSeconds)
    model.refresh()
    #expect(model.code == nil && model.pairingLink == nil)
    #expect(model.detail == "The code expired; show a new one.")
    let device = RemoteDevices.Device(
        name: "iPhone, Safari", tokenHash: String(repeating: "ab", count: 32), pairedSeconds: 0,
        lastSeenSeconds: 0)
    let registry = RemoteDeviceRegistry(RemoteDevices(devices: [device]), save: { _ in })
    let listing = RemoteModel(remoteControls(registry: registry))
    #expect(listing.devices.map(\.name) == ["iPhone, Safari"])
    try listing.forget(0)
    #expect(listing.devices.isEmpty && registry.devices.isEmpty)
}
