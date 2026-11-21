import Foundation
import Settings
import Testing

@testable import Remote

/// A clock tests move by hand.
final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds = 1_000_000.0
    var now: Double { lock.withLock { seconds } }
    func advance(_ by: Double) { lock.withLock { seconds += by } }
}

@Test func aCodeIsSixDigitsAndPairsOneDeviceOnce() throws {
    let pairing = RemotePairing()
    let code = pairing.newCode()
    #expect(code.count == 6 && code.allSatisfy(\.isNumber))
    #expect(throws: Never.self) { try pairing.trade(code) }
    #expect(throws: RemotePairing.Refusal.noCode) { try pairing.trade(code) }
    #expect(pairing.status == .none(reason: nil))
}

@Test func aCodeExpiresAfterTwoMinutes() {
    let clock = Clock()
    let pairing = RemotePairing(now: { clock.now })
    let code = pairing.newCode()
    clock.advance(119)
    #expect(pairing.status == .live(code: code, secondsLeft: 1))
    clock.advance(1)
    #expect(pairing.status == .none(reason: "the code expired; show a new one"))
    #expect(throws: RemotePairing.Refusal.noCode) { try pairing.trade(code) }
}

@Test func fiveWrongCodesKillTheCodeUntilANewOneIsShown() throws {
    let pairing = RemotePairing()
    let code = pairing.newCode()
    let wrong = code == "000000" ? "111111" : "000000"
    for _ in 0..<4 {
        #expect(throws: RemotePairing.Refusal.wrong) { try pairing.trade(wrong) }
    }
    #expect(throws: RemotePairing.Refusal.wrong) { try pairing.trade("12") }
    #expect(throws: RemotePairing.Refusal.noCode) { try pairing.trade(code) }
    #expect(pairing.status == .none(reason: "5 wrong codes were tried; show a new one"))
    let next = pairing.newCode()
    #expect(throws: Never.self) { try pairing.trade(next) }
}

@Test func theConstantTimeCompareMatchesOnlyEqualBytes() {
    #expect(constantTimeEqual([1, 2, 3], [1, 2, 3]))
    #expect(!constantTimeEqual([1, 2, 3], [1, 2, 4]))
    #expect(!constantTimeEqual([0, 2, 3], [1, 2, 3]))
}

/// A registry whose saves land in `saved`.
final class Saves: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [RemoteDevices] = []
    var last: RemoteDevices? { lock.withLock { all.last } }
    var count: Int { lock.withLock { all.count } }
    func save(_ devices: RemoteDevices) { lock.withLock { all.append(devices) } }
}

@Test func theRegistryKeepsOnlyTheTokensHashAndChecksItAgainstEveryDevice() throws {
    let saves = Saves()
    let clock = Clock()
    let registry = RemoteDeviceRegistry(
        RemoteDevices(devices: []), save: { saves.save($0) }, now: { clock.now })
    let first = try registry.pair(name: "iPhone, Safari")
    let second = try registry.pair(name: "Mac, Safari")
    #expect(first.count == 32 && first != second)
    let stored = try #require(saves.last)
    #expect(stored.devices.map(\.tokenHash) == [tokenHash(first), tokenHash(second)])
    #expect(!stored.devices.contains { $0.tokenHash.contains(first) })
    #expect(stored.problem() == nil)
    #expect(registry.device(authorization: "Bearer \(second)")?.name == "Mac, Safari")
    for refused in [
        nil, second, "Bearer", "bearer \(second)", "Bearer \(second.uppercased())",
        "Bearer \(second)0", "Bearer " + String(repeating: "0", count: 32),
    ] {
        #expect(registry.device(authorization: refused) == nil, "\(refused ?? "nil")")
    }
}

@Test func lastSeenIsSavedOnlyOnceItsTenMinutesStale() throws {
    let saves = Saves()
    let clock = Clock()
    let registry = RemoteDeviceRegistry(
        RemoteDevices(devices: []), save: { saves.save($0) }, now: { clock.now })
    let token = try registry.pair(name: "iPhone, Safari")
    clock.advance(599)
    _ = registry.device(authorization: "Bearer \(token)")
    #expect(saves.count == 1)
    clock.advance(1)
    _ = registry.device(authorization: "Bearer \(token)")
    #expect(saves.count == 2)
    #expect(saves.last?.devices.first?.lastSeenSeconds == clock.now)
}

@Test func forgettingADeviceEndsItsTokenAndTellsItsStreams() throws {
    let saves = Saves()
    let registry = RemoteDeviceRegistry(RemoteDevices(devices: []), save: { saves.save($0) })
    let gone = Saves()
    registry.forgotten = { hash in
        gone.save(
            RemoteDevices(devices: [
                .init(name: "x", tokenHash: hash, pairedSeconds: 0, lastSeenSeconds: 0)
            ]))
    }
    let token = try registry.pair(name: "iPhone, Safari")
    try registry.forget(tokenHash: tokenHash(token))
    #expect(registry.device(authorization: "Bearer \(token)") == nil)
    #expect(saves.last?.devices == [])
    #expect(gone.last?.devices.first?.tokenHash == tokenHash(token))
}

@Test func aFullListMakesRoomByTheDeviceSeenLeastRecentlyAndClosesItsStreams() throws {
    let clock = Clock()
    let registry = RemoteDeviceRegistry(
        RemoteDevices(devices: []), save: { _ in }, now: { clock.now })
    var tokens: [String] = []
    for index in 0..<RemoteDevices.capacity {
        tokens.append(try registry.pair(name: "Device \(index)"))
        clock.advance(1)
    }
    let gone = Saves()
    registry.forgotten = { hash in
        gone.save(
            RemoteDevices(devices: [
                .init(name: "x", tokenHash: hash, pairedSeconds: 0, lastSeenSeconds: 0)
            ]))
    }
    _ = try registry.pair(name: "New")
    #expect(gone.last?.devices.first?.tokenHash == tokenHash(tokens[0]))
    #expect(registry.devices.count == RemoteDevices.capacity)
    #expect(registry.device(authorization: "Bearer \(tokens[0])") == nil)
    #expect(registry.devices.last?.name == "New")
}

/// Waits up to five seconds for `condition`, recording an issue when it never holds.
func waitFor(_ condition: @escaping () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !condition() {
        guard Date() < deadline else {
            Issue.record("the condition never held")
            return
        }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
}
