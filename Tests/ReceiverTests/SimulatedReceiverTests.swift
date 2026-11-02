import Foundation
import Testing

@testable import Fixtures
@testable import LocalNetwork
@testable import Receiver
@testable import UPnP

private let loopback = NetworkInterface(
    name: "lo0", index: 1, address: IPAddress("127.0.0.1")!, prefixLength: 8)

/// A receiver on loopback: each connection waits for the test to drive it.
private final class SimulatedReceiver: @unchecked Sendable {
    let server: LoopbackServer
    private let peers: Peers

    init() async throws {
        let peers = Peers()
        server = try await LoopbackServer { connection in peers.add(connection) }
        self.peers = peers
    }

    var port: UInt16 { server.port }

    /// The `index`th connection, once it comes.
    func peer(_ index: Int = 0) async throws -> LoopbackConnection {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let peer = peers.peer(index) { return peer }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        throw LoopbackTimeout(seen: "no connection \(index)", closed: false)
    }

    func stop() { server.stop() }
}

private final class Peers: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [LoopbackConnection] = []

    func add(_ peer: LoopbackConnection) { lock.withLock { all.append(peer) } }

    func peer(_ index: Int) -> LoopbackConnection? {
        lock.withLock { index < all.count ? all[index] : nil }
    }
}

extension LoopbackConnection {
    /// The next `count` lines the app sent, without their carriage returns.
    fileprivate func lines(_ count: Int, seconds: Double = 2) async throws -> [String] {
        var lines: [String] = []
        for _ in 0..<count {
            let line = try await receive(through: [0x0D], seconds: seconds)
            lines.append(String(decoding: line.dropLast(), as: UTF8.self))
        }
        return lines
    }
}

private func denon(_ address: String = "127.0.0.1", udn: String = "uuid:1") -> Renderer {
    Renderer(
        udn: udn, name: "AVR-X1800H", manufacturer: "Denon", model: "AVR-X1800H",
        location: try! LocalURL("http://\(address):60006/d.xml", on: loopback), sinkFormats: [])
}

private final class ProblemLog: @unchecked Sendable {
    private let lock = NSLock()
    private var heard: [ReceiverControl.Problem] = []

    func add(_ problem: ReceiverControl.Problem) { lock.withLock { heard.append(problem) } }

    var all: [ReceiverControl.Problem] { lock.withLock { heard } }
}

/// A control aimed at `port`, with what it reported.
@MainActor
private func control(
    port: UInt16, renderers: [Renderer] = [denon()], fallback: String? = nil,
    interfaces: [NetworkInterface] = [loopback]
) -> (ReceiverControl, ProblemLog) {
    var outcome = RendererDiscovery.Outcome()
    outcome.renderers = renderers
    let found = outcome
    let log = ProblemLog()
    let control = ReceiverControl(
        discover: { found }, fallback: { fallback.flatMap(IPAddress.init) },
        interfaces: { interfaces }, problem: log.add, port: port)
    return (control, log)
}

/// Waits up to two seconds for `condition`, failing with what the control shows.
@MainActor
private func wait(
    _ control: ReceiverControl, _ log: ProblemLog, _ what: String, _ condition: () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(2)
    while !condition() {
        guard Date() < deadline else {
            Issue.record("\(what) never held: \(control.status), \(control.state), \(log.all)")
            return
        }
        try await Task.sleep(nanoseconds: 2_000_000)
    }
}

@MainActor @Test func theModelFollowsPushedLinesNotWhatWasSent() async throws {
    let receiver = try await SimulatedReceiver()
    defer { receiver.stop() }
    let (control, log) = control(port: receiver.port)
    control.start()
    let peer = try await receiver.peer()
    #expect(try await peer.lines(5) == ["PW?", "MV?", "MU?", "SI?", "MS?"])
    try await wait(control, log, "connected") { control.status == .connected("AVR-X1800H") }
    try await peer.send("PWON\rMV455\rMUOFF\rSICD\rMSSTEREO\rCVFL 50\r")
    try await wait(control, log, "the answers taken") { control.state.soundMode == "STEREO" }
    #expect(control.state.isOn == true)
    #expect(control.state.volume?.decibels == -34.5)
    #expect(control.state.isMuted == false)
    #expect(control.state.input == .cd)
    // The app asks; the model waits for the receiver to say.
    control.run(.soundMode(.pureDirect))
    #expect(try await peer.lines(1) == ["MSPURE DIRECT"])
    try await Task.sleep(nanoseconds: 100_000_000)
    #expect(control.state.isIn(.stereo))
    // The receiver's own remote changes it, and the model follows.
    try await peer.send("MSDIRECT\rMV50\rMUON\r")
    try await wait(control, log, "the remote's change") { control.state.isMuted == true }
    #expect(control.state.isIn(.direct))
    #expect(control.state.volume?.decibels == -30)
    #expect(log.all == [])
}

@MainActor @Test func unknownValuesAreReportedAndTheRestKept() async throws {
    let receiver = try await SimulatedReceiver()
    defer { receiver.stop() }
    let (control, log) = control(port: receiver.port)
    control.start()
    let peer = try await receiver.peer()
    try await peer.send("MV50\rSICD\r")
    try await wait(control, log, "volume") { control.state.input == .cd }
    try await peer.send("MV999\rSIHEOS MUSIC\r")
    try await peer.send([0x4D, 0x55, 0xFF, 0x0D])
    try await wait(control, log, "the input unknown") { control.state.input == nil }
    #expect(control.state.volume?.decibels == -30)
    try await wait(control, log, "three reports") { log.all.count == 3 }
    #expect(
        log.all == [
            .ignored("a value out of range: MV999"),
            .ignored("an input it has no name for: SIHEOS MUSIC"),
            .ignored("a line that isn't printable ASCII"),
        ])
    #expect(control.status == .connected("AVR-X1800H"))
    // Past the cap, one line says the rest aren't reported.
    try await peer.send(String(repeating: "MV999\r", count: 30))
    try await Task.sleep(nanoseconds: 200_000_000)
    #expect(log.all.count == ReceiverControl.ignoredLineCap + 1)
}

@MainActor @Test func anOversizeLineDropsTheConnection() async throws {
    let receiver = try await SimulatedReceiver()
    defer { receiver.stop() }
    let (control, log) = control(port: receiver.port)
    control.start()
    let peer = try await receiver.peer()
    // A line of exactly the cap is fine; one byte more without a CR isn't.
    try await peer.send("MS" + String(repeating: "A", count: ReceiverConnection.lineCap - 2) + "\r")
    try await peer.send(String(repeating: "B", count: ReceiverConnection.lineCap + 1))
    try await wait(control, log, "unreachable") {
        if case .unreachable = control.status { true } else { false }
    }
    #expect(log.all.contains(.unreachable("\(ReceiverConnection.End.overlongLine)")))
    #expect(await peer.closes(within: 2))
}

@MainActor @Test func aLineWithoutItsCRWaitsForIt() async throws {
    let receiver = try await SimulatedReceiver()
    defer { receiver.stop() }
    let (control, log) = control(port: receiver.port)
    control.start()
    let peer = try await receiver.peer()
    try await wait(control, log, "connected") { control.status == .connected("AVR-X1800H") }
    try await peer.send("MV50")
    try await Task.sleep(nanoseconds: 200_000_000)
    #expect(control.state.volume == nil)
    try await peer.send("\r")
    try await wait(control, log, "the line taken") { control.state.volume?.decibels == -30 }
}

@MainActor @Test func aRefusedConnectionIsUnreachableAndNotRetried() async throws {
    let port = LoopbackServer.refusingPort
    let (control, log) = control(port: port)
    control.start()
    try await wait(control, log, "unreachable") {
        if case .unreachable = control.status { true } else { false }
    }
    try await Task.sleep(nanoseconds: 300_000_000)
    #expect(log.all.count == 1)
    #expect(log.all.first?.description.contains("refused") == true, "\(log.all)")
    // The owner's next command tries once more.
    control.run(.volumeUp)
    try await wait(control, log, "a second report") { log.all.count == 2 }
}

@MainActor @Test func aDroppedConnectionIsUnreachableAndNotRetried() async throws {
    let receiver = try await SimulatedReceiver()
    defer { receiver.stop() }
    let (control, log) = control(port: receiver.port)
    control.start()
    let peer = try await receiver.peer()
    try await wait(control, log, "connected") { control.status == .connected("AVR-X1800H") }
    peer.close()
    try await wait(control, log, "unreachable") {
        if case .unreachable = control.status { true } else { false }
    }
    #expect(log.all.count == 1)
    try await Task.sleep(nanoseconds: 300_000_000)
    #expect(receiver.server.connectionCount == 1)
    control.run(.mute(true))
    let second = try await receiver.peer(1)
    #expect(try await second.lines(1) == ["MUON"])
    try await wait(control, log, "connected again") { control.status == .connected("AVR-X1800H") }
}

@MainActor @Test func onlyOneDenonOnTheSubnetIsControlled() async throws {
    let other = Renderer(
        udn: "uuid:tv", name: "TV", manufacturer: "Acme", model: "TV",
        location: try LocalURL("http://127.0.0.1:1/d.xml", on: loopback), sinkFormats: [])
    for (renderers, why) in [
        ([other], "no Denon receiver answered on the local network"),
        (
            [denon(), denon("127.0.0.2", udn: "uuid:2")],
            "2 Denon receivers answered, at 127.0.0.1, 127.0.0.2; receiver control works with one"
        ),
    ] {
        let (control, log) = control(port: 1, renderers: renderers)
        control.start()
        try await wait(control, log, "unreachable") { control.status == .unreachable(why) }
        #expect(!control.hasReceiver)
        control.run(.volumeUp)
        #expect(log.all == [.unreachable(why), .unreachable("no receiver was found")])
    }
}

@MainActor @Test func stoppingClosesTheConnectionAndForgetsTheReceiver() async throws {
    let receiver = try await SimulatedReceiver()
    defer { receiver.stop() }
    let (control, log) = control(port: receiver.port)
    control.start()
    let peer = try await receiver.peer()
    try await peer.send("PWON\r")
    try await wait(control, log, "on") { control.state.isOn == true }
    control.stop()
    #expect(control.status == .stopped)
    #expect(control.state == ReceiverState())
    #expect(!control.hasReceiver)
    #expect(await peer.closes(within: 2))
    #expect(log.all == [])
}

/// The connection on its own, for the spacing of what it sends.
private func connection(_ receiver: SimulatedReceiver) -> ReceiverConnection {
    let connection = ReceiverConnection(address: IPAddress("127.0.0.1")!, port: receiver.port) {
        _ in
    }
    connection.start()
    return connection
}

@Test func aHeldKeyIsThrottledAndStopsWhenLetGo() async throws {
    let receiver = try await SimulatedReceiver()
    defer { receiver.stop() }
    let sender = connection(receiver)
    defer { sender.stop() }
    let peer = try await receiver.peer()
    // A key held for half a second at 30 repeats a second.
    for _ in 0..<15 {
        sender.send(ReceiverCommand.volumeUp.line)
        try await Task.sleep(nanoseconds: 33_000_000)
    }
    try await Task.sleep(nanoseconds: 200_000_000)
    let times = sender.sentTimes
    #expect(times.count >= 8 && times.count <= 15, "\(times.count) sent")
    for (earlier, later) in zip(times, times.dropFirst()) {
        #expect(later - earlier >= ReceiverConnection.commandGapSeconds)
    }
    #expect(try await peer.lines(times.count) == Array(repeating: "MVUP", count: times.count))
    // Nothing more once the key is let go.
    try await Task.sleep(nanoseconds: 200_000_000)
    #expect(sender.sentTimes.count == times.count)
}

@Test func commandsAreSpacedAndWaitASecondAfterPowerOn() async throws {
    let receiver = try await SimulatedReceiver()
    defer { receiver.stop() }
    let sender = connection(receiver)
    defer { sender.stop() }
    let peer = try await receiver.peer()
    for command in [ReceiverCommand.power(true), .volumeUp, .volumeDown, .mute(true)] {
        sender.send(command.line)
    }
    #expect(try await peer.lines(4, seconds: 3) == ["PWON", "MVUP", "MVDOWN", "MUON"])
    let times = sender.sentTimes
    #expect(times[1] - times[0] >= ReceiverConnection.powerOnGapSeconds)
    #expect(times[2] - times[1] >= ReceiverConnection.commandGapSeconds)
    #expect(times[3] - times[2] >= ReceiverConnection.commandGapSeconds)
}

@Test func linesPastTheWaitingCapAreRefused() async throws {
    let receiver = try await SimulatedReceiver()
    defer { receiver.stop() }
    let sender = connection(receiver)
    defer { sender.stop() }
    _ = try await receiver.peer()
    sender.send(ReceiverCommand.power(true).line)
    let accepted = (0..<40).map { index in
        sender.send(ReceiverCommand.setVolume(ReceiverVolume(halfSteps: index)!).line)
    }
    #expect(accepted.filter { $0 }.count >= ReceiverConnection.waitingCap)
    #expect(accepted.contains(false))
}

@MainActor @Test func theConfiguredAddressIsUsedWhenTheSearchFindsNone() async throws {
    let receiver = try await SimulatedReceiver()
    defer { receiver.stop() }
    let (control, log) = control(port: receiver.port, renderers: [], fallback: "127.0.0.1")
    control.start()
    let peer = try await receiver.peer()
    #expect(try await peer.lines(1) == ["PW?"])
    try await wait(control, log, "connected") {
        control.status == .connected("the receiver at 127.0.0.1")
    }
    #expect(log.all == [])
}

@MainActor @Test func aConfiguredAddressOffTheSubnetIsRefused() async throws {
    let receiver = try await SimulatedReceiver()
    defer { receiver.stop() }
    let lan = NetworkInterface(
        name: "en0", index: 4, address: IPAddress("10.0.0.5")!, prefixLength: 24)
    let (control, log) = control(
        port: receiver.port, renderers: [], fallback: "127.0.0.1", interfaces: [lan])
    control.start()
    let why =
        "no Denon receiver answered on the local network, and the receiver address 127.0.0.1"
        + " isn't on a local subnet"
    try await wait(control, log, "unreachable") { control.status == .unreachable(why) }
    try await Task.sleep(nanoseconds: 200_000_000)
    #expect(receiver.server.connectionCount == 0)
    #expect(log.all.first?.description.hasSuffix(ReceiverControl.unreachableHint) == true)
}

@MainActor @Test func aDenonFoundBySearchWinsOverTheConfiguredAddress() async throws {
    let receiver = try await SimulatedReceiver()
    defer { receiver.stop() }
    // The configured address is off every subnet, so using it would fail.
    let (control, log) = control(port: receiver.port, fallback: "192.0.2.1")
    control.start()
    try await wait(control, log, "connected") { control.status == .connected("AVR-X1800H") }
}
