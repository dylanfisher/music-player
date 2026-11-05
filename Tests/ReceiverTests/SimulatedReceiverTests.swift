import Foundation
import Testing

@testable import Fixtures
@testable import LocalNetwork
@testable import Receiver
@testable import UPnP

/// A made-up interface on 127/8, so stand-ins at 127.0.0.1 count as other devices.
private let loopback = NetworkInterface(
    name: "lo9", index: 1, address: IPAddress("127.0.0.2")!, prefixLength: 8)

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

private func denon(
    _ address: String = "127.0.0.1", udn: String = "uuid:1", model: String = "Denon AVR-X1800H",
    name: String = "AVR-X1800H"
) -> Renderer {
    Renderer(
        udn: udn, name: name, manufacturer: "Denon", model: model,
        location: try! LocalURL("http://\(address):60006/d.xml", on: loopback), sinkFormats: [])
}

private final class ProblemLog: @unchecked Sendable {
    private let lock = NSLock()
    private var heard: [ReceiverControl.Problem] = []

    func add(_ problem: ReceiverControl.Problem) { lock.withLock { heard.append(problem) } }

    var all: [ReceiverControl.Problem] { lock.withLock { heard } }
}

/// A control aimed at `port`, with what it reported.
/// What a fake discovery finds, which a test can change, and how often it ran.
private final class Discovery: @unchecked Sendable {
    private let lock = NSLock()
    private var found: [Renderer]
    private var count = 0

    init(_ renderers: [Renderer]) { found = renderers }

    var renderers: [Renderer] {
        get { lock.withLock { found } }
        set { lock.withLock { found = newValue } }
    }

    var runs: Int { lock.withLock { count } }

    func run() -> RendererDiscovery.Outcome {
        var outcome = RendererDiscovery.Outcome()
        outcome.renderers = lock.withLock {
            count += 1
            return found
        }
        return outcome
    }
}

@MainActor
private func control(
    port: UInt16, renderers: [Renderer] = [denon()], fallback: String? = nil,
    interfaces: [NetworkInterface] = [loopback], discovery: Discovery? = nil
) -> (ReceiverControl, ProblemLog) {
    let discovery = discovery ?? Discovery(renderers)
    let log = ProblemLog()
    let control = ReceiverControl(
        discover: { discovery.run() }, fallback: { fallback.flatMap(IPAddress.init) },
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

/// Starts `control` and answers its first query, as a receiver does.
@MainActor
private func connected(
    _ control: ReceiverControl, _ log: ProblemLog, _ receiver: SimulatedReceiver,
    peer index: Int = 0
) async throws -> LoopbackConnection {
    let peer = try await receiver.peer(index)
    try await peer.send("PWON\r")
    try await wait(control, log, "connected") {
        if case .connected = control.status { true } else { false }
    }
    return peer
}

@MainActor
private func isUnreachable(_ control: ReceiverControl) -> Bool {
    if case .unreachable = control.status { true } else { false }
}

@MainActor @Test func theModelFollowsPushedLinesNotWhatWasSent() async throws {
    let receiver = try await SimulatedReceiver()
    defer { receiver.stop() }
    let (control, log) = control(port: receiver.port)
    control.start()
    let peer = try await receiver.peer()
    #expect(try await peer.lines(5) == ["PW?", "MV?", "MU?", "SI?", "MS?"])
    // Connected only once the receiver says something.
    #expect(control.status == .connecting("AVR-X1800H"))
    try await peer.send("PWON\rMV455\rMUOFF\rSICD\rMSSTEREO\rCVFL 50\r")
    try await wait(control, log, "the answers taken") { control.state.soundMode == "STEREO" }
    #expect(control.status == .connected("AVR-X1800H"))
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

@MainActor @Test func anOversizeLineDropsTheConnectionAndClearsTheModel() async throws {
    let receiver = try await SimulatedReceiver()
    defer { receiver.stop() }
    let (control, log) = control(port: receiver.port)
    control.start()
    let peer = try await connected(control, log, receiver)
    try await wait(control, log, "on") { control.state.isOn == true }
    let listener = try #require(control.listening)
    // A line of exactly the cap is fine; one byte more without a CR isn't.
    try await peer.send("MS" + String(repeating: "A", count: ReceiverConnection.lineCap - 2) + "\r")
    try await peer.send(String(repeating: "B", count: ReceiverConnection.lineCap + 1))
    try await wait(control, log, "unreachable") { isUnreachable(control) }
    #expect(log.all.contains(.unreachable("\(ReceiverConnection.End.overlongLine)")))
    #expect(await peer.closes(within: 2))
    // No check mark shows what the receiver said before, and nothing waits on the old stream.
    #expect(control.state == ReceiverState())
    #expect(listener.isCancelled)
}

@MainActor @Test func aFloodOfLinesDropsTheConnection() async throws {
    let receiver = try await SimulatedReceiver()
    defer { receiver.stop() }
    let (control, log) = control(port: receiver.port)
    control.start()
    let peer = try await connected(control, log, receiver)
    try await peer.send(
        String(repeating: "CVFL 50\r", count: ReceiverConnection.linesPerSecondCap + 50))
    try await wait(control, log, "unreachable") { isUnreachable(control) }
    #expect(log.all.contains(.unreachable("\(ReceiverConnection.End.flooding)")))
    #expect(await peer.closes(within: 2))
}

@MainActor @Test func aLineWithoutItsCRWaitsForItAndCRLFIsALineEnd() async throws {
    let receiver = try await SimulatedReceiver()
    defer { receiver.stop() }
    let (control, log) = control(port: receiver.port)
    control.start()
    let peer = try await connected(control, log, receiver)
    try await peer.send("MV50")
    try await Task.sleep(nanoseconds: 200_000_000)
    #expect(control.state.volume == nil)
    try await peer.send("\r")
    try await wait(control, log, "the line taken") { control.state.volume?.decibels == -30 }
    try await peer.send("MV40\r\nSIGAME\r\n")
    try await wait(control, log, "CRLF lines taken") { control.state.input == .game }
    #expect(control.state.volume?.decibels == -40)
    #expect(log.all == [])
}

@MainActor @Test func aSilentConnectionIsUnreachableWithTheReason() async throws {
    let receiver = try await SimulatedReceiver()
    defer { receiver.stop() }
    let (control, log) = control(port: receiver.port)
    control.start()
    let peer = try await receiver.peer()
    #expect(try await peer.lines(5).count == 5)
    #expect(control.status == .connecting("AVR-X1800H"))
    try await wait(control, log, "unreachable") { isUnreachable(control) }
    #expect(log.all == [.unreachable("\(ReceiverConnection.End.silent)")])
    #expect(log.all.first?.description.contains("HEOS or AVR Remote") == true)
}

@MainActor @Test func aRefusedConnectionIsUnreachableAndNotRetried() async throws {
    let port = LoopbackServer.refusingPort
    let discovery = Discovery([denon()])
    let (control, log) = control(port: port, discovery: discovery)
    control.start()
    try await wait(control, log, "unreachable") { isUnreachable(control) }
    try await Task.sleep(nanoseconds: 300_000_000)
    #expect(log.all.count == 1)
    #expect(log.all.first?.description.contains("refused") == true, "\(log.all)")
    #expect(log.all.first?.description.hasSuffix(ReceiverControl.unreachableHint) == true)
    #expect(discovery.runs == 1)
    // The owner's next command searches and tries once more.
    control.run(.volumeUp)
    try await wait(control, log, "a second report") { log.all.count == 2 }
    #expect(discovery.runs == 2)
}

@MainActor @Test func aDroppedConnectionIsFoundAgainOnlyByACommand() async throws {
    let receiver = try await SimulatedReceiver()
    defer { receiver.stop() }
    let discovery = Discovery([denon()])
    let (control, log) = control(port: receiver.port, discovery: discovery)
    control.start()
    let peer = try await connected(control, log, receiver)
    peer.close()
    try await wait(control, log, "unreachable") { isUnreachable(control) }
    #expect(log.all.count == 1)
    try await Task.sleep(nanoseconds: 300_000_000)
    #expect(receiver.server.connectionCount == 1)
    #expect(discovery.runs == 1)
    // The command searches again, since the receiver may have moved, then is sent.
    control.run(.mute(true))
    let second = try await receiver.peer(1)
    #expect(try await second.lines(1) == ["MUON"])
    #expect(discovery.runs == 2)
    try await second.send("MUON\r")
    try await wait(control, log, "connected again") { control.status == .connected("AVR-X1800H") }
}

@MainActor @Test func aReceiverNotFoundAtFirstIsFoundByACommand() async throws {
    let receiver = try await SimulatedReceiver()
    defer { receiver.stop() }
    let discovery = Discovery([])
    let (control, log) = control(port: receiver.port, discovery: discovery)
    control.start()
    try await wait(control, log, "unreachable") { isUnreachable(control) }
    discovery.renderers = [denon()]
    control.run(.input(.game))
    let peer = try await receiver.peer()
    #expect(try await peer.lines(1) == ["SIGAME"])
    #expect(discovery.runs == 2)
}

@MainActor @Test func theReceiverIsChosenAmongDenonsByAddressThenByModel() async throws {
    let receiver = try await SimulatedReceiver()
    defer { receiver.stop() }
    let speaker = denon("127.0.0.3", udn: "uuid:home", model: "Denon Home 150", name: "Kitchen")
    // A Denon Home answering alongside the receiver is passed over.
    let (byModel, modelLog) = control(port: receiver.port, renderers: [speaker, denon()])
    byModel.start()
    _ = try await connected(byModel, modelLog, receiver)
    byModel.stop()
    // Two receivers: the configured address picks one.
    let other = denon("127.0.0.3", udn: "uuid:2", name: "Den")
    let (byAddress, addressLog) = control(
        port: receiver.port, renderers: [other, denon()], fallback: "127.0.0.1")
    byAddress.start()
    _ = try await connected(byAddress, addressLog, receiver, peer: 1)
    byAddress.stop()
    // Without one, it says which answered.
    let (unsure, unsureLog) = control(port: receiver.port, renderers: [other, denon()])
    unsure.start()
    let why =
        "2 Denon receivers answered: AVR-X1800H at 127.0.0.1, Den at 127.0.0.3; set"
        + " receiver.address to the one to control"
    try await wait(unsure, unsureLog, "unsure") { unsure.status == .unreachable(why) }
}

@MainActor @Test func noDenonReceiverIsReportedAgainOnACommand() async throws {
    let other = Renderer(
        udn: "uuid:tv", name: "TV", manufacturer: "Acme", model: "TV",
        location: try LocalURL("http://127.0.0.1:1/d.xml", on: loopback), sinkFormats: [])
    let why = "no Denon receiver answered on the local network"
    let (control, log) = control(port: 1, renderers: [other])
    control.start()
    try await wait(control, log, "unreachable") { control.status == .unreachable(why) }
    control.run(.volumeUp)
    try await wait(control, log, "reported again") { log.all.count == 2 }
    #expect(log.all == [.unreachable(why), .unreachable(why)])
}

@MainActor @Test func stoppingClosesTheConnectionAndForgetsTheState() async throws {
    let receiver = try await SimulatedReceiver()
    defer { receiver.stop() }
    let (control, log) = control(port: receiver.port)
    control.start()
    let peer = try await connected(control, log, receiver)
    try await wait(control, log, "on") { control.state.isOn == true }
    control.stop()
    #expect(control.status == .stopped)
    #expect(control.state == ReceiverState())
    #expect(await peer.closes(within: 2))
    #expect(log.all == [])
}

@MainActor @Test func turningTheSettingOffStopsASearchUnderWay() async throws {
    let cancelled = LoopbackOnce<Bool>()
    let control = ReceiverControl(
        discover: {
            do {
                try await Task.sleep(nanoseconds: 10_000_000_000)
            } catch {
                cancelled.set(true)
                throw error
            }
            return RendererDiscovery.Outcome()
        }, fallback: { nil }, interfaces: { [] }, problem: { _ in }, port: 1)
    let running = ReceiverControl.applying(enabled: true, to: nil, make: { control })
    #expect(running === control)
    #expect(control.status == .searching)
    #expect(ReceiverControl.applying(enabled: false, to: running, make: { control }) == nil)
    #expect(control.status == .stopped)
    #expect(try await cancelled.value(seconds: 1))
}

@MainActor @Test func turningTheSettingOffClosesTheConnection() async throws {
    let receiver = try await SimulatedReceiver()
    defer { receiver.stop() }
    let (made, log) = control(port: receiver.port)
    let running = ReceiverControl.applying(enabled: true, to: nil, make: { made })
    let peer = try await connected(made, log, receiver)
    #expect(ReceiverControl.applying(enabled: false, to: running, make: { made }) == nil)
    #expect(made.status == .stopped)
    #expect(await peer.closes(within: 2))
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
    // A receiver says something at once, or the connection is taken for a silent one.
    try await peer.send("PWON\r")
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

@Test func aDraggedLevelReplacesTheOneWaitingAndEndsOnTheLast() async throws {
    let receiver = try await SimulatedReceiver()
    defer { receiver.stop() }
    let sender = connection(receiver)
    defer { sender.stop() }
    let peer = try await receiver.peer()
    try await peer.send("PWON\r")
    // Power on holds the next line back a second, so every level below waits behind it.
    sender.send(ReceiverCommand.power(true).line)
    for halfSteps in 60...90 {
        sender.send(ReceiverCommand.setVolume(ReceiverVolume(halfSteps: halfSteps)!).line)
    }
    sender.send(ReceiverCommand.volumeUp.line)
    sender.send(ReceiverCommand.setVolume(ReceiverVolume(halfSteps: 20)!).line)
    #expect(try await peer.lines(4, seconds: 3) == ["PWON", "MV45", "MVUP", "MV10"])
    try await Task.sleep(nanoseconds: 200_000_000)
    #expect(sender.sentTimes.count == 4)
}

@Test func commandsAreSpacedAndWaitASecondAfterPowerOn() async throws {
    let receiver = try await SimulatedReceiver()
    defer { receiver.stop() }
    let sender = connection(receiver)
    defer { sender.stop() }
    let peer = try await receiver.peer()
    // A receiver says something at once, or the connection is taken for a silent one.
    try await peer.send("PWON\r")
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
    try await receiver.peer().send("PWON\r")
    sender.send(ReceiverCommand.power(true).line)
    let accepted = (0..<40).map { index in
        sender.send(ReceiverCommand.mute(index % 2 == 0).line)
    }
    #expect(accepted.filter { $0 == .queued }.count >= ReceiverConnection.waitingCap)
    #expect(accepted.contains(.full))
    // Once it's ending, a line says so rather than claiming the queue is full.
    sender.stop()
    #expect(sender.send(ReceiverCommand.volumeUp.line) == .ended)
}

@MainActor @Test func theConfiguredAddressIsUsedWhenTheSearchFindsNone() async throws {
    let receiver = try await SimulatedReceiver()
    defer { receiver.stop() }
    let (control, log) = control(port: receiver.port, renderers: [], fallback: "127.0.0.1")
    control.start()
    let peer = try await receiver.peer()
    #expect(try await peer.lines(1) == ["PW?"])
    _ = try await connected(control, log, receiver)
    #expect(control.status == .connected("the receiver at 127.0.0.1"))
    #expect(log.all == [])
}

@MainActor @Test func aConfiguredAddressThatIsntAnotherDeviceIsRefused() async throws {
    for text in ["127.0.0.2", "127.0.0.0", "127.255.255.255"] {
        let (control, log) = control(port: 1, renderers: [], fallback: text)
        control.start()
        let why =
            "no Denon receiver answered on the local network, and the receiver address \(text)"
            + " isn't another device's address on a local subnet"
        try await wait(control, log, "unreachable") { control.status == .unreachable(why) }
    }
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
        + " isn't another device's address on a local subnet"
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
    _ = try await connected(control, log, receiver)
    #expect(control.status == .connected("AVR-X1800H"))
}

@Test func theControlConnectionNeverGoesThroughAProxy() {
    let connection = ReceiverConnection(address: IPAddress("127.0.0.1")!, port: 1) { _ in }
    #expect(connection.bypassesProxies)
}

@Test func playingToTheDenonRunsReceiverControlForItsVolume() {
    #expect(!ReceiverControl.isWanted(enabled: false, playingTo: nil))
    #expect(ReceiverControl.isWanted(enabled: true, playingTo: nil))
    #expect(ReceiverControl.isWanted(enabled: false, playingTo: denon()))
    // A HEOS speaker or a Sonos has a volume of its own; the setting alone decides.
    #expect(!ReceiverControl.isWanted(enabled: false, playingTo: denon(model: "Denon Home 150")))
}

@Test func theAccessibilityPromptComesOnceEverThenTheStatusLineSaysHow() {
    typealias Access = ReceiverControl.VolumeKeyAccess
    func access(_ permitted: Bool, _ prompted: Bool, _ explained: Bool) -> Access {
        ReceiverControl.volumeKeyAccess(
            permitted: permitted, promptedBefore: prompted, explainedThisLaunch: explained)
    }
    #expect(access(false, false, false) == .prompt)
    // Declined: never prompted again, told once a launch where to grant it.
    #expect(access(false, true, false) == .explain)
    #expect(access(false, true, true) == .nothing)
    #expect(access(true, true, true) == .tap)
    #expect(
        ReceiverControl.accessibilityHint.contains("Security & Privacy › Privacy › Accessibility"))
}

@Test func theVolumeKeysDriveTheReceiverOnlyWhilePlayingToIt() {
    #expect(
        ReceiverControl.takesVolumeKeys(setting: true, controlRunning: true, playingTo: denon()))
    #expect(
        !ReceiverControl.takesVolumeKeys(setting: false, controlRunning: true, playingTo: denon()))
    #expect(
        !ReceiverControl.takesVolumeKeys(setting: true, controlRunning: false, playingTo: denon()))
    #expect(!ReceiverControl.takesVolumeKeys(setting: true, controlRunning: true, playingTo: nil))
    #expect(
        !ReceiverControl.takesVolumeKeys(
            setting: true, controlRunning: true, playingTo: denon(model: "Denon Home 150")))
}
