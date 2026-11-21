import Foundation
import Remote
import Settings

/// What Settings ▸ Remote reads of the web remote: its code, where a phone opens the page while
/// it's on, and the paired devices, which can be forgotten while it's off too.
public struct RemoteControls {
    public var pairing: RemotePairing
    public var devices: () -> RemoteDeviceRegistry?
    /// Nil while the remote is off.
    public var links: () -> RemoteLinks?

    public init(
        pairing: RemotePairing, devices: @escaping () -> RemoteDeviceRegistry?,
        links: @escaping () -> RemoteLinks?
    ) {
        self.pairing = pairing
        self.devices = devices
        self.links = links
    }
}

/// Settings ▸ Remote's pairing box and device list, without AppKit (ADR 0214).
@MainActor
final class RemoteModel {
    struct Device: Equatable {
        var name: String
        var paired: String
        var lastSeen: String
        var tokenHash: String
    }

    let controls: RemoteControls
    /// The code in groups of three, nil while none is live.
    private(set) var code: String?
    private(set) var detail = ""
    /// The link the QR code holds, nil while no code is live.
    private(set) var pairingLink: String?
    /// Where the page is, by name and by address, for a phone that doesn't scan the code.
    private(set) var addresses: String?
    private(set) var devices: [Device] = []
    private(set) var canShowCode = false

    init(_ controls: RemoteControls) {
        self.controls = controls
        refresh()
    }

    /// Reads the code, its time left and the devices again; the pane does once a second.
    func refresh() {
        let links = controls.links()
        canShowCode = links != nil
        addresses = links.map { links in
            links.lan.map { "\(links.local)  or  \($0)" } ?? links.local
        }
        code = nil
        pairingLink = nil
        if let links {
            switch controls.pairing.status {
            case .live(let live, let secondsLeft):
                code = live.prefix(3) + " " + live.dropFirst(3)
                pairingLink = links.pairing(live)
                let seconds = Int(secondsLeft.rounded(.up))
                detail =
                    "Scan the code with the phone, or open the address and type the code. It"
                    + " ends in \(seconds / 60):\(String(format: "%02d", seconds % 60))."
            case .none(let reason):
                detail =
                    reason.map { $0.prefix(1).uppercased() + $0.dropFirst() + "." }
                    ?? "Show a code to pair a phone."
            }
        } else {
            detail = "Turn on the web remote to pair a phone."
        }
        devices = (controls.devices()?.devices ?? []).map { device in
            Device(
                name: device.name,
                paired: LibraryDatabase.writtenText(
                    Date(timeIntervalSince1970: device.pairedSeconds)),
                lastSeen: LibraryDatabase.writtenText(
                    Date(timeIntervalSince1970: device.lastSeenSeconds)),
                tokenHash: device.tokenHash)
        }
    }

    /// Shows a new code, which ends any other.
    func showCode() {
        guard canShowCode else { return }
        controls.pairing.newCode()
        refresh()
    }

    /// Forgets the device at `index`: its token stops working and its streams close.
    func forget(_ index: Int) throws {
        guard devices.indices.contains(index), let registry = controls.devices() else { return }
        try registry.forget(tokenHash: devices[index].tokenHash)
        refresh()
    }
}
