import Commands
import Foundation
import Playback
import Receiver
import Scripting
import Settings
import Testing

@testable import Fixtures
@testable import LocalNetwork
@testable import Remote

private let loopback = NetworkInterface(
    name: "lo0", index: 1, address: IPAddress("127.0.0.1")!, prefixLength: 8)
private let ownID = String(repeating: "a", count: 32)
private let otherID = String(repeating: "b", count: 32)

/// Records what was advertised, and lets a test say what the browser finds.
private final class FakeBonjour: BonjourAdvertising, BonjourBrowsing, @unchecked Sendable {
    // Guarded by `lock`.
    private let lock = NSLock()
    private var adverts: [BonjourAdvert] = []
    private var found: (@Sendable ([BonjourFound]) -> Void)?
    private var stops = 0

    func start(_ advert: BonjourAdvert, problem: @escaping @Sendable (String) -> Void) {
        lock.withLock { adverts.append(advert) }
    }

    func start(
        type: String, found: @escaping @Sendable ([BonjourFound]) -> Void,
        problem: @escaping @Sendable (String) -> Void
    ) {
        lock.withLock { self.found = found }
    }

    func stop() { lock.withLock { stops += 1 } }

    var advertised: [BonjourAdvert] { lock.withLock { adverts } }
    func find(_ services: [BonjourFound]) { lock.withLock { found }?(services) }
}

/// A service on loopback over a fake Bonjour, whose state and commands tests set and see.
private final class Fixture: @unchecked Sendable {
    // Guarded by `lock`.
    private let lock = NSLock()
    private var ran: [(CommandID, String?)] = []
    private var heard: [String] = []
    var current: RemoteState
    let bonjour = FakeBonjour()
    let saves = Saves()
    var service: RemoteService!

    init() {
        current = RemoteState(
            instance: ownID, name: "Studio", state: .paused, track: nil, positionSeconds: 10,
            positionReadAt: 0, queueStamp: 1, queueLength: 0, queuePosition: nil, shuffle: false,
            repeatMode: "off", volumeDecibels: nil, output: nil, receiver: nil, lastPlayedAt: nil)
        service = RemoteService(
            identity: .init(id: ownID, name: "Studio", host: "Studio"),
            devices: RemoteDeviceRegistry(
                RemoteDevices(devices: []),
                save: { [saves] in
                    saves.save($0)
                }),
            page: Array("<html>remote</html>".utf8),
            state: { [self] in lock.withLock { current } },
            run: { [self] id, argument in
                lock.withLock { ran.append((id, argument)) }
                return id == .removeTracks
                    ? .failed("\(id) doesn't run from the web remote") : .done(nil)
            },
            advertiser: bonjour, browser: bonjour,
            problem: { [self] message in lock.withLock { heard.append(message) } },
            sleep: { _ in try await Task.sleep(nanoseconds: 2_000_000) })
    }

    deinit { service?.stop() }

    var commands: [String] { lock.withLock { ran.map { "\($0.0) \($0.1 ?? "-")" } } }
    var problems: [String] { lock.withLock { heard } }
    func set(_ change: (inout RemoteState) -> Void) { lock.withLock { change(&current) } }

    var port: UInt16 { service.listeningPort ?? 0 }
    var host: String { "127.0.0.1:\(port)" }

    func start(port: UInt16 = 0) async throws { try await service.follow([loopback], port: port) }

    /// Sends one request on a new connection and reads its reply.
    func send(
        _ method: String, _ path: String, token: String? = nil, body: String? = nil,
        fields: String = ""
    ) async throws -> (status: Int, head: String, body: String) {
        let connection = try await LoopbackConnection.connect(port: port)
        defer { connection.close() }
        var request = "\(method) \(path) HTTP/1.1\r\nHost: \(host)\r\n\(fields)"
        if let token { request += "Authorization: Bearer \(token)\r\n" }
        if let body {
            request +=
                "Content-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n"
                + body
        } else {
            request += "\r\n"
        }
        try await connection.send(request)
        let head = String(
            decoding: try await connection.receive(through: Array("\r\n\r\n".utf8)),
            as: UTF8.self)
        let status = try #require(Int(head.split(separator: " ")[1]))
        let length =
            head.split(separator: "\r\n").first { $0.hasPrefix("Content-Length: ") }
            .flatMap { Int($0.dropFirst("Content-Length: ".count)) } ?? 0
        let bytes = length == 0 ? [] : try await connection.receive(count: length)
        return (status, head, String(decoding: bytes, as: UTF8.self))
    }

    /// Pairs a device with a fresh code, returning its token.
    func pair() async throws -> String {
        let code = service.pairing.newCode()
        let reply = try await send(
            "POST", "/api/pair", body: #"{"code": "\#(code)", "device": "iPhone, Safari"}"#)
        #expect(reply.status == 200, "\(reply.body)")
        let object = try JSONSerialization.jsonObject(with: Data(reply.body.utf8)) as? [String: Any]
        #expect(object?["instance"] as? String == ownID)
        return try #require(object?["token"] as? String)
    }
}

@Test func everyRouteButThePageAndTheTradeIsA401WithNothingInItWithoutAToken() async throws {
    let fixture = Fixture()
    try await fixture.start()
    let token = try await fixture.pair()
    let wrong = String(repeating: "0", count: 32)
    let routes = [
        ("GET", "/api/state"), ("GET", "/api/events"), ("GET", "/api/instances"),
        ("POST", "/api/command"), ("GET", "/api/nothing"), ("GET", "/secret"),
        ("POST", "/api/state"),
    ]
    for (method, path) in routes {
        for sent in [nil, wrong, token.uppercased()] {
            let reply = try await fixture.send(
                method, path, token: sent, body: method == "POST" ? "{}" : nil)
            #expect(reply.status == 401, "\(method) \(path)")
            #expect(reply.body.isEmpty)
            #expect(!reply.head.contains("WWW-Authenticate"))
        }
    }
    #expect(try await fixture.send("GET", "/").body == "<html>remote</html>")
    #expect(try await fixture.send("GET", "/api/nothing", token: token).status == 404)
    #expect(try await fixture.send("POST", "/api/state", token: token, body: "{}").status == 405)
}

@Test func aPairedDeviceReadsTheStateAndTheMacKeepsOnlyItsTokensHash() async throws {
    let fixture = Fixture()
    try await fixture.start()
    let token = try await fixture.pair()
    let state = try await fixture.send("GET", "/api/state", token: token)
    #expect(state.status == 200)
    #expect(state.head.contains("Content-Type: application/json"))
    #expect(state.body.contains(#""instance":"\#(ownID)""#))
    #expect(state.body.contains(#""state":"paused""#))
    let saved = try #require(fixture.saves.last)
    #expect(saved.devices.map(\.name) == ["iPhone, Safari"])
    #expect(saved.devices.map(\.tokenHash) == [tokenHash(token)])
    let file = String(decoding: try JSONEncoder().encode(saved), as: UTF8.self)
    #expect(!file.contains(token))
}

@Test func aTradeIsRefusedForAWrongCodeAnUnknownKeyOrAnotherMediaType() async throws {
    let fixture = Fixture()
    try await fixture.start()
    let code = fixture.service.pairing.newCode()
    let wrong = code == "000000" ? "111111" : "000000"
    let refusals: [(String, String, Int)] = [
        (#"{"code": "\#(wrong)", "device": "Phone"}"#, "", 403),
        (#"{"code": "\#(code)", "device": "Phone", "admin": true}"#, "", 400),
        (#"{"code": "\#(code)"}"#, "", 400),
        (#"{"code": "\#(code)", "device": ""}"#, "", 400),
        (#"["\#(code)"]"#, "", 400),
    ]
    for (body, _, status) in refusals {
        let reply = try await fixture.send("POST", "/api/pair", body: body)
        #expect(reply.status == status, "\(body)")
        #expect(reply.body.contains(#""error""#))
    }
    let connection = try await LoopbackConnection.connect(port: fixture.port)
    defer { connection.close() }
    let body = #"{"code": "\#(code)", "device": "Phone"}"#
    try await connection.send(
        "POST /api/pair HTTP/1.1\r\nHost: \(fixture.host)\r\nContent-Type: text/plain\r\n"
            + "Content-Length: \(body.utf8.count)\r\n\r\n\(body)")
    let head = String(
        decoding: try await connection.receive(through: Array("\r\n\r\n".utf8)), as: UTF8.self)
    #expect(head.hasPrefix("HTTP/1.1 415"))
    // One wrong guess was counted; the code still pairs.
    _ = try await fixture.send("POST", "/api/pair", body: body)
    #expect(fixture.service.devices.devices.count == 1)
}

@Test func commandsGoToTheRouterAndAnUnremotableOneIsRefused() async throws {
    let fixture = Fixture()
    try await fixture.start()
    let token = try await fixture.pair()
    let next = try await fixture.send(
        "POST", "/api/command", token: token, body: #"{"name": "playback.next"}"#)
    #expect(next.status == 200)
    let seek = try await fixture.send(
        "POST", "/api/command", token: token,
        body: #"{"name": "playback.seekTo", "argument": "30"}"#)
    #expect(seek.status == 200)
    let remove = try await fixture.send(
        "POST", "/api/command", token: token, body: #"{"name": "track.remove"}"#)
    #expect(remove.status == 400)
    #expect(remove.body.contains("doesn't run from the web remote"))
    let extra = try await fixture.send(
        "POST", "/api/command", token: token, body: #"{"name": "playback.next", "x": 1}"#)
    #expect(extra.status == 400)
    #expect(fixture.commands == ["playback.next -", "playback.seekTo 30", "track.remove -"])
}

@Test func anEventStreamSendsTheStateThenEachChangeAndClosesWhenTheDeviceIsForgotten()
    async throws
{
    let fixture = Fixture()
    try await fixture.start()
    let token = try await fixture.pair()
    let connection = try await LoopbackConnection.connect(port: fixture.port)
    defer { connection.close() }
    try await connection.send(
        "GET /api/events HTTP/1.1\r\nHost: \(fixture.host)\r\nAuthorization: Bearer \(token)"
            + "\r\n\r\n")
    let head = String(
        decoding: try await connection.receive(through: Array("\r\n\r\n".utf8)), as: UTF8.self)
    #expect(head.contains("Content-Type: text/event-stream"))
    let first = String(
        decoding: try await connection.receive(through: Array("\n\n".utf8)), as: UTF8.self)
    #expect(first.hasPrefix("data: {") && first.contains(#""state":"paused""#))
    fixture.set { $0.state = .playing }
    let second = String(
        decoding: try await connection.receive(through: Array("\n\n".utf8)), as: UTF8.self)
    #expect(second.contains(#""state":"playing""#))
    try fixture.service.devices.forget(tokenHash: tokenHash(token))
    #expect(await connection.closes(within: 3))
}

@Test func theInstancesAreThisOneAndTheOthersOnItsSubnetsWhoseOriginsCORSLetsIn() async throws {
    let fixture = Fixture()
    try await fixture.start()
    let token = try await fixture.pair()
    let advert = try #require(fixture.bonjour.advertised.last)
    #expect(advert.type == "_music-player._tcp")
    #expect(advert.name == "Studio")
    #expect(
        advert.txt == [
            "id": ownID, "host": "Studio", "port": "\(fixture.port)", "addr": "127.0.0.1",
        ])
    #expect(!advert.txt.values.contains { $0.contains("playing") || $0.contains("paused") })
    let other = "http://127.0.0.9:47800"
    fixture.bonjour.find([
        BonjourFound(
            name: "Living Room",
            txt: [
                "id": otherID, "host": "mbp", "port": "47800",
                "addr": "127.0.0.9,10.9.9.9",
            ]),
        BonjourFound(name: "Studio", txt: advert.txt),
        BonjourFound(
            name: "Away",
            txt: [
                "id": String(repeating: "c", count: 32), "host": "away",
                "port": "47800", "addr": "10.9.9.9",
            ]),
        BonjourFound(name: "Junk", txt: ["id": "x"]),
    ])
    let listed = try await fixture.send("GET", "/api/instances", token: token)
    let instances = try #require(
        try JSONSerialization.jsonObject(with: Data(listed.body.utf8)) as? [[String: Any]])
    #expect(instances.map { $0["id"] as? String } == [ownID, otherID])
    #expect(instances.last?["addresses"] as? [String] == ["127.0.0.9"])
    let allowed = try await fixture.send(
        "GET", "/api/state", token: token, fields: "Origin: \(other)\r\n")
    #expect(allowed.head.contains("Access-Control-Allow-Origin: \(other)"))
    let byName = try await fixture.send(
        "GET", "/api/state", token: token, fields: "Origin: http://mbp.local:47800\r\n")
    #expect(byName.status == 200)
    for refused in ["http://10.9.9.9:47800", "http://away.local:47800", "http://evil.example"] {
        let reply = try await fixture.send(
            "GET", "/api/state", token: token, fields: "Origin: \(refused)\r\n")
        #expect(reply.status == 403, "\(refused)")
    }
    #expect(fixture.problems.contains { $0.contains("\"Junk\"") })
    fixture.bonjour.find([])
    #expect(
        try await fixture.send("GET", "/api/state", token: token, fields: "Origin: \(other)\r\n")
            .status == 403)
}

@Test func stoppingClosesEveryConnectionAndEndsTheCode() async throws {
    let fixture = Fixture()
    try await fixture.start()
    let token = try await fixture.pair()
    let port = fixture.port
    let connection = try await LoopbackConnection.connect(port: port)
    defer { connection.close() }
    try await connection.send(
        "GET /api/events HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer \(token)"
            + "\r\n\r\n")
    _ = try await connection.receive(through: Array("data: ".utf8))
    fixture.service.pairing.newCode()
    fixture.service.stop()
    #expect(await connection.closes(within: 3))
    #expect(fixture.service.pairing.status == .none(reason: nil))
    #expect(fixture.service.listeningPort == nil)
    await #expect(throws: (any Error).self) {
        try await LoopbackConnection.connect(port: port)
    }
}

@Test func aStateIsNewsWhenAnythingButThePlayingPositionChanges() {
    let fixture = Fixture()
    var before = fixture.current
    before.state = .playing
    var after = before
    after.positionReadAt = 2
    after.positionSeconds = 12
    #expect(!after.isNews(after: before))
    after.positionSeconds = 13.5
    #expect(after.isNews(after: before))
    after.positionSeconds = 12
    after.volumeDecibels = -10
    #expect(after.isNews(after: before))
    before.state = .paused
    after = before
    after.positionReadAt = 2
    #expect(!after.isNews(after: before))
    after.positionSeconds = 12
    #expect(after.isNews(after: before))
}

@Test func theQueueStampMovesWithTheQueueAndTheLastPlayTimeWithEachStart() {
    var stamp = RemoteQueueStamp()
    var state = PlaybackState()
    stamp.note(state, at: 1)
    #expect(stamp.stamp == 0 && stamp.lastPlayedAt == nil)
    state.queue = [URL(fileURLWithPath: "/a.flac", isDirectory: false)]
    state.order = [0]
    state.currentIndex = 0
    stamp.note(state, at: 2)
    #expect(stamp.stamp == 1)
    state.status = .playing
    stamp.note(state, at: 3)
    stamp.note(state, at: 4)
    #expect(stamp.lastPlayedAt == 3)
    state.status = .paused
    stamp.note(state, at: 5)
    state.status = .playing
    stamp.note(state, at: 6)
    #expect(stamp.lastPlayedAt == 6)
    #expect(stamp.stamp == 1)
    let built = RemoteState(
        identity: .init(id: ownID, name: "Studio", host: "Studio"), playback: state,
        position: .nan, readAt: 7, track: nil, queue: stamp, volumeDecibels: nil, output: nil,
        receiver: nil)
    #expect(built.positionSeconds == nil)
    #expect(built.queuePosition == 1 && built.state == .playing && built.lastPlayedAt == 6)
}

@Test func thePairingLinkNamesTheMacsLocalNameAndTheLANAddressIsBesideIt() async throws {
    let fixture = Fixture()
    #expect(fixture.service.links == nil)
    try await fixture.start()
    let links = try #require(fixture.service.links)
    #expect(links.local == "http://studio.local:\(fixture.port)")
    #expect(links.lan == "http://127.0.0.1:\(fixture.port)")
    #expect(links.pairing("123456") == "http://studio.local:\(fixture.port)/#pair=123456")
}

/// A loopback port nothing listens on now, found by listening on one the system picks.
private func freePort() async throws -> UInt16 {
    let probe = Fixture()
    try await probe.start()
    let port = probe.port
    let server = probe.service.currentServer
    probe.service.stop()
    await server?.closed()
    return port
}

@Test func twoFollowsAtOnceLeaveOneServerListening() async throws {
    let fixture = Fixture()
    async let first: Void = fixture.service.follow([loopback], port: 0)
    async let second: Void = fixture.service.follow([loopback], port: 0)
    _ = try await (first, second)
    #expect(fixture.service.listeningPort != nil)
    #expect(try await fixture.send("GET", "/").status == 200)
}

@Test func aStopWhileAStartBindsLeavesNothingListeningAndALaterStartListens() async throws {
    let fixture = Fixture()
    let port = try await freePort()
    let starting = fixture.service.followTask([loopback], port: port)
    fixture.service.stop()
    try await starting.value.get()
    #expect(fixture.service.listeningPort == nil)
    await #expect(throws: (any Error).self) { try await LoopbackConnection.connect(port: port) }
    let again = fixture.service.followTask([loopback], port: port)
    fixture.service.stop()
    try await fixture.service.follow([loopback], port: port)
    try await again.value.get()
    #expect(fixture.service.listeningPort == port)
    #expect(try await fixture.send("GET", "/").status == 200)
}

@Test func aPortChangeDuringAStartLeavesOnlyTheNewPortBound() async throws {
    let fixture = Fixture()
    let old = try await freePort()
    let new = try await freePort()
    // Both are queued before either binds, the new port last, as a setting change would.
    let first = fixture.service.followTask([loopback], port: old)
    let second = fixture.service.followTask([loopback], port: new)
    try await first.value.get()
    try await second.value.get()
    #expect(fixture.service.listeningPort == new)
    await #expect(throws: (any Error).self) { try await LoopbackConnection.connect(port: old) }
}

@Test func aLostListenerStartsTheServerAgain() async throws {
    let fixture = Fixture()
    try await fixture.start()
    let before = try #require(fixture.service.currentServer)
    before.loseFirstListener()
    try await waitFor {
        fixture.service.currentServer.map { $0 !== before } == true
            && fixture.service.listeningPort != nil
    }
    #expect(try await fixture.send("GET", "/").status == 200)
    #expect(fixture.problems.contains { $0.hasPrefix("the web remote stopped listening") })
}

@Test func aDeviceHoldsAtMostFourEventStreams() async throws {
    let fixture = Fixture()
    try await fixture.start()
    let token = try await fixture.pair()
    var open: [LoopbackConnection] = []
    defer { for connection in open { connection.close() } }
    for _ in 0..<RemoteEventHub.streamsPerDevice {
        let connection = try await LoopbackConnection.connect(port: fixture.port)
        try await connection.send(
            "GET /api/events HTTP/1.1\r\nHost: \(fixture.host)\r\nAuthorization: Bearer \(token)"
                + "\r\n\r\n")
        _ = try await connection.receive(through: Array("data: ".utf8))
        open.append(connection)
    }
    #expect(try await fixture.send("GET", "/api/events", token: token).status == 503)
    let other = try await fixture.pair()
    let connection = try await LoopbackConnection.connect(port: fixture.port)
    defer { connection.close() }
    try await connection.send(
        "GET /api/events HTTP/1.1\r\nHost: \(fixture.host)\r\nAuthorization: Bearer \(other)"
            + "\r\n\r\n")
    _ = try await connection.receive(through: Array("data: ".utf8))
}

@Test func advertsClaimingOneIDWithDifferentAddressesAreAllLeftOutAndNamesAreMadeSafe()
    async throws
{
    let fixture = Fixture()
    try await fixture.start()
    let token = try await fixture.pair()
    func advert(_ name: String, _ id: String, _ address: String) -> BonjourFound {
        BonjourFound(name: name, txt: ["id": id, "host": "mbp", "port": "47800", "addr": address])
    }
    let third = String(repeating: "c", count: 32)
    fixture.bonjour.find([
        advert("Real", otherID, "127.0.0.9"), advert("Impostor", otherID, "127.0.0.10"),
        advert("Same\u{1B}[31m" + String(repeating: "x", count: 300), third, "127.0.0.11"),
        advert("Twice", third, "127.0.0.11"),
    ])
    let listed = try await fixture.send("GET", "/api/instances", token: token)
    let instances = try #require(
        try JSONSerialization.jsonObject(with: Data(listed.body.utf8)) as? [[String: Any]])
    #expect(instances.map { $0["id"] as? String } == [ownID, third])
    let name = try #require(instances.last?["name"] as? String)
    #expect(!name.unicodeScalars.contains { $0.value < 0x20 } && name.count <= 256)
    #expect(fixture.problems.filter { $0.contains("claim one ID") }.count == 1)
    fixture.bonjour.find([
        advert("Real", otherID, "127.0.0.9"), advert("Impostor", otherID, "127.0.0.10"),
    ])
    #expect(fixture.problems.filter { $0.contains("claim one ID") }.count == 1)
}

@Test func theOutputReceiverAndTrackAreReadFromPlainInputs() throws {
    let options = outputOptions(
        devices: [FoundOutput(id: "dac", name: "DAC")], renderers: [], current: .device(uid: "dac"))
    #expect(
        RemoteState.Output(current: .device(uid: "dac"), among: options)
            == RemoteState.Output(choice: "output:device:dac", name: "DAC"))
    #expect(RemoteState.Output(current: .renderer(udn: "x"), among: options) == nil)
    var said = ReceiverState()
    said.isOn = true
    said.input = .cd
    #expect(
        RemoteState.Receiver(said)
            == RemoteState.Receiver(isOn: true, volumeDecibels: nil, isMuted: nil, input: "CD"))
    var cache = RemoteTrackCache()
    var lookups = 0
    let track = RemoteState.Track(
        id: 1, albumID: 2, title: "A", artist: nil, album: nil, durationSeconds: 3)
    for _ in 0..<3 {
        #expect(
            try cache.track(at: "/a.flac") { _ in
                lookups += 1
                return track
            } == track)
    }
    #expect(lookups == 1)
    #expect(
        try cache.track(at: nil) { _ in
            Issue.record("looked up")
            return nil
        } == nil)
    struct Broken: Error {}
    #expect(throws: Broken.self) { try cache.track(at: "/b.flac") { _ in throw Broken() } }
    #expect(
        try cache.track(at: "/b.flac") { _ in
            Issue.record("asked again")
            return nil
        } == nil)
}
