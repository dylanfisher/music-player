import CommonCrypto
import Foundation
import Settings

/// The paired devices, by the SHA-256 of their tokens (ADR 0214). A token is 128 random bits as
/// 32 hex digits; only its hash is kept, in the state file through `save`, so the Mac holds
/// nothing a request could send. Its list is guarded by `lock`.
public final class RemoteDeviceRegistry: @unchecked Sendable {
    /// How stale a device's last-seen time may get before a request writes it again, so a busy
    /// page doesn't rewrite the state file on every request.
    static let seenSeconds = 600.0
    static let tokenDigits = 32

    private let lock = NSLock()
    private var list: RemoteDevices
    private let save: @Sendable (RemoteDevices) throws -> Void
    private let now: @Sendable () -> Double
    /// Called with a device's hash once it's forgotten, so its event streams close.
    var forgotten: @Sendable (String) -> Void = { _ in }

    public init(
        _ devices: RemoteDevices, save: @escaping @Sendable (RemoteDevices) throws -> Void,
        now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }
    ) {
        list = devices
        self.save = save
        self.now = now
    }

    public var devices: [RemoteDevices.Device] { lock.withLock { list.devices } }

    /// Pairs a device named `name`, returning its token. The oldest-seen device makes room
    /// when the list is full.
    func pair(name: String) throws -> String {
        var generator = SystemRandomNumberGenerator()
        let token = (0..<2).map { _ in generator.next() as UInt64 }
            .map { String(repeating: "0", count: 16) + String($0, radix: 16) }
            .map { String($0.suffix(16)) }.joined()
        let time = now()
        try lock.withLock {
            var next = list
            if next.devices.count >= RemoteDevices.capacity,
                let oldest = next.devices.indices.min(by: {
                    next.devices[$0].lastSeenSeconds < next.devices[$1].lastSeenSeconds
                })
            {
                next.devices.remove(at: oldest)
            }
            next.devices.append(
                RemoteDevices.Device(
                    name: name, tokenHash: tokenHash(token), pairedSeconds: time,
                    lastSeenSeconds: time))
            try save(next)
            list = next
        }
        return token
    }

    /// The device `authorization`, a request's `Authorization` field, names by its bearer
    /// token; nil for anything else. Every stored hash is compared, in constant time, so the
    /// time taken says nothing of which one, if any, was close.
    func device(authorization: String?) -> RemoteDevices.Device? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        let token = authorization.dropFirst("Bearer ".count)
        guard token.utf8.count == Self.tokenDigits, token.utf8.allSatisfy(isLowerHex) else {
            return nil
        }
        let hash = Array(tokenHash(String(token)).utf8)
        return lock.withLock { () -> RemoteDevices.Device? in
            var found: Int?
            for (index, device) in list.devices.enumerated() {
                let stored = Array(device.tokenHash.utf8)
                if stored.count == hash.count, constantTimeEqual(stored, hash) { found = index }
            }
            guard let found else { return nil }
            let time = now()
            if time - list.devices[found].lastSeenSeconds >= Self.seenSeconds {
                var next = list
                next.devices[found].lastSeenSeconds = time
                do {
                    try save(next)
                    list = next
                } catch {
                    // The request still goes: a last-seen time is only shown, never checked.
                    reportSaveFailure("\(error)")
                }
            }
            return list.devices[found]
        }
    }

    /// Called when a last-seen time couldn't be saved.
    var reportSaveFailure: @Sendable (String) -> Void = { _ in }

    /// Unpairs the device with `tokenHash`: its token stops working, and its streams close.
    public func forget(tokenHash: String) throws {
        try lock.withLock {
            var next = list
            next.devices.removeAll { $0.tokenHash == tokenHash }
            try save(next)
            list = next
        }
        forgotten(tokenHash)
    }
}

/// A token's SHA-256 as 64 lowercase hex digits.
func tokenHash(_ token: String) -> String {
    let bytes = Array(token.utf8)
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    _ = CC_SHA256(bytes, CC_LONG(bytes.count), &digest)
    return digest.map { String(format: "%02x", $0) }.joined()
}

private func isLowerHex(_ byte: UInt8) -> Bool {
    (0x30...0x39).contains(byte) || (0x61...0x66).contains(byte)
}
