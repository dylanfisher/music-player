import Foundation
import Testing

@testable import Fixtures
@testable import LocalNetwork
@testable import UPnP

/// A captured document from the owner's network, scrubbed: `denon-description.xml` and the like.
func captured(_ name: String) throws -> String {
    let url = try #require(
        Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil), "\(name)")
    return try String(contentsOf: url, encoding: .utf8)
}

/// A MediaRenderer on loopback that answers as the captured one does: its description,
/// AVTransport description and sink list are the owner's captures, and its AVTransport keeps a
/// transport state the way a renderer does, on the wall clock. It fetches each URI it's given,
/// with a `Range`, as a renderer would. Tests make it refuse, stall, stop on its own or vanish.
final class FakeRenderer: @unchecked Sendable {
    enum State: String {
        case stopped = "STOPPED"
        case playing = "PLAYING"
        case paused = "PAUSED_PLAYBACK"
    }

    struct Fetch: Equatable {
        var status: Int
        var body: [UInt8]
    }

    let description: String
    let scpd: String
    let protocolInfo: String
    private(set) var server: LoopbackServer!
    private let lock = NSLock()

    // What tests set.
    private var trackSecondsValue: Double
    private var refusing: [String: Int] = [:]
    private var stalling: Set<String> = []
    private var startsPlaying = true
    private var advancesToNext = true
    private var keepsNext = false
    private var reencodes = false

    // What it holds.
    private var uri = ""
    private var nextURI = ""
    private var state = State.stopped
    private var seconds = 0.0
    private var since: Double?
    private var log: [String] = []
    private var metadata: [String] = []
    private var fetches: [Fetch] = []
    private var vanished = false
    /// Each URI SetAVTransportURI gave it, with the state it was in when it came.
    private var setURIs: [(uri: String, stateBefore: State)] = []

    init(
        description: String, scpd: String, protocolInfo: String, trackSeconds: Double = 60
    ) async throws {
        self.description = description
        self.scpd = scpd
        self.protocolInfo = protocolInfo
        trackSecondsValue = trackSeconds
        server = try await LoopbackServer { [weak self] connection in
            await self?.answer(connection)
        }
    }

    /// The Denon's captures, or the Sonos's.
    static func denon(trackSeconds: Double = 60, scpd: String? = nil) async throws -> FakeRenderer {
        try await FakeRenderer(
            description: try captured("denon-description.xml"),
            scpd: try scpd ?? captured("denon-avtransport-scpd.xml"),
            protocolInfo: try captured("denon-protocolinfo.xml"), trackSeconds: trackSeconds)
    }

    static func sonos() async throws -> FakeRenderer {
        try await FakeRenderer(
            description: try captured("sonos-description.xml"),
            scpd: try captured("sonos-avtransport-scpd.xml"),
            protocolInfo: try captured("sonos-protocolinfo.xml"))
    }

    var port: UInt16 { server.port }

    /// Where its description is, as its SSDP reply would say.
    var location: String {
        let path =
            description.contains("aios_device")
            ? "/upnp/desc/aios_device/aios_device.xml"
            : "/xml/device_description.xml"
        return "http://127.0.0.1:\(port)\(path)"
    }

    func refuse(_ action: String, code: Int) { lock.withLock { refusing[action] = code } }
    func stall(_ action: String) { lock.withLock { _ = stalling.insert(action) } }
    func answersAgain() { lock.withLock { stalling = [] } }
    /// Keeps the first next track it's given, as a renderer that has already started
    /// buffering it does.
    func keepsFirstNext() { lock.withLock { keepsNext = true } }
    /// Reports its URI with the token's first character percent-encoded and the scheme in
    /// capitals, as a renderer that rewrites what it was given might.
    func reencodesURIs() { lock.withLock { reencodes = true } }

    /// Pauses it as its own remote would.
    func pauseOnItsOwn() {
        lock.withLock {
            seconds = position
            since = nil
            state = .paused
        }
    }
    func neverStarts() { lock.withLock { startsPlaying = false } }
    func ignoresNext() { lock.withLock { advancesToNext = false } }
    func setTrackSeconds(_ value: Double) { lock.withLock { trackSecondsValue = value } }

    /// Stops it as its own remote would.
    func stopOnItsOwn() {
        lock.withLock {
            state = .stopped
            seconds = 0
            since = nil
        }
    }

    /// Gives it another stream, as another app would.
    func playOther() {
        lock.withLock {
            uri = "http://192.0.2.9/other"
            state = .playing
        }
    }

    /// Every action it was sent, in order.
    var actions: [String] { lock.withLock { log } }
    /// The actions that change something, without the polls.
    var commands: [String] { actions.filter { !$0.hasPrefix("Get") } }
    var transportState: State {
        lock.withLock {
            tick()
            return state
        }
    }
    var currentURI: String { lock.withLock { uri } }
    var nextTrackURI: String { lock.withLock { nextURI } }
    var lastMetadata: String? { lock.withLock { metadata.last } }
    var fetched: [Fetch] { lock.withLock { fetches } }
    var playedSeconds: Double {
        lock.withLock {
            tick()
            return position
        }
    }

    /// Each SetAVTransportURI's URI and the state the renderer was in when it came.
    var setTransportURIs: [(uri: String, stateBefore: State)] { lock.withLock { setURIs } }

    /// `uri` as GetPositionInfo reports it. Call under the lock.
    private func reported(_ uri: String) -> String {
        guard reencodes, uri.hasPrefix("http"), let slash = uri.lastIndex(of: "/") else {
            return uri
        }
        let token = uri[uri.index(after: slash)...]
        guard let first = token.first?.asciiValue else { return uri }
        return "HTTP" + uri[uri.index(uri.startIndex, offsetBy: 4)..<slash] + "/"
            + String(format: "%%%02X", first) + token.dropFirst()
    }

    private var now: Double { ProcessInfo.processInfo.systemUptime }
    private var position: Double { seconds + (since.map { now - $0 } ?? 0) }

    /// Moves time on: a track that has played out goes on to the next one it was given, or
    /// stops. Call under the lock.
    private func tick() {
        guard state == .playing, position >= trackSecondsValue else { return }
        if advancesToNext, !nextURI.isEmpty {
            uri = nextURI
            nextURI = ""
            seconds = 0
            since = now
        } else {
            state = .stopped
            seconds = 0
            since = nil
        }
    }

    private func answer(_ connection: LoopbackConnection) async {
        do {
            let head = String(
                decoding: try await connection.receive(through: Array("\r\n\r\n".utf8)),
                as: UTF8.self)
            let lines = head.split(separator: "\r\n")
            let path = String(lines[0].split(separator: " ")[1])
            let length =
                lines.first { $0.hasPrefix("Content-Length: ") }
                .flatMap { Int($0.dropFirst("Content-Length: ".count)) } ?? 0
            let body = String(
                decoding: length > 0 ? try await connection.receive(count: length) : [],
                as: UTF8.self)
            if head.hasPrefix("GET") {
                try await connection.send(ok(path.contains("AVTransport") ? scpd : description))
            } else if path.contains("ConnectionManager") {
                try await connection.send(ok(protocolInfo))
            } else {
                let action =
                    lines.first { $0.hasPrefix("SOAPACTION: ") }
                    .flatMap { $0.split(separator: "#").last }.map { String($0.dropLast()) } ?? ""
                guard let reply = await perform(action, body) else {
                    // Stalled: say nothing until the client gives up.
                    _ = await connection.closes(within: 10)
                    return
                }
                try await connection.send(reply)
            }
            connection.close()
        } catch {
            // Vanishing cancels the connections it had open.
            if !lock.withLock({ vanished }) { Issue.record("the fake renderer failed: \(error)") }
        }
    }

    /// The reply to `action`, or nil when it stalls.
    private func perform(_ action: String, _ body: String) async -> String? {
        let (stalls, code, fetchURI) = lock.withLock {
            () -> (Bool, Int?, String?) in
            log.append(action)
            if stalling.contains(action) { return (true, nil, nil) }
            if let code = refusing[action] { return (false, code, nil) }
            tick()
            var fetch: String?
            switch action {
            case "SetAVTransportURI":
                setURIs.append((argument("CurrentURI", body), state))
                uri = argument("CurrentURI", body)
                metadata.append(argument("CurrentURIMetaData", body))
                state = .stopped
                seconds = 0
                since = nil
                fetch = uri
            case "SetNextAVTransportURI":
                if !keepsNext || nextURI.isEmpty { nextURI = argument("NextURI", body) }
            case "Play":
                if startsPlaying, !uri.isEmpty, state != .playing {
                    state = .playing
                    since = now
                }
            case "Pause":
                seconds = position
                since = nil
                state = .paused
            case "Stop":
                state = .stopped
                seconds = 0
                since = nil
            case "Seek":
                seconds = upnpSeconds(argument("Target", body)) ?? seconds
                if state == .playing { since = now }
            default:
                break
            }
            return (false, nil, fetch)
        }
        if stalls { return nil }
        if let code { return fault(code) }
        if let fetchURI { await fetchStart(of: fetchURI) }
        return lock.withLock {
            switch action {
            case "GetTransportInfo":
                ok(
                    response(
                        action,
                        "<CurrentTransportState>\(state.rawValue)</CurrentTransportState>"
                            + "<CurrentTransportStatus>OK</CurrentTransportStatus>"
                            + "<CurrentSpeed>1</CurrentSpeed>"))
            case "GetPositionInfo":
                ok(
                    response(
                        action,
                        "<Track>1</Track><TrackDuration>\(upnpTime(trackSecondsValue)).\(Int(trackSecondsValue * 1000) % 1000)"
                            + "</TrackDuration><TrackMetaData></TrackMetaData>"
                            + "<TrackURI>\(xmlEscaped(reported(uri)))</TrackURI>"
                            + "<RelTime>\(upnpTime(state == .stopped ? 0 : position))</RelTime>"
                            + "<AbsTime>NOT_IMPLEMENTED</AbsTime>"))
            default:
                ok(response(action, ""))
            }
        }
    }

    /// Fetches the first 100 bytes of `uri` as a renderer starting a stream would.
    private func fetchStart(of uri: String) async {
        guard let url = URL(string: uri), let port = url.port else {
            Issue.record("the renderer was given \(uri)")
            return
        }
        do {
            let connection = try await LoopbackConnection.connect(port: UInt16(port))
            defer { connection.close() }
            try await connection.send(
                "GET \(url.path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nRange: bytes=0-99\r\n\r\n")
            let reply = try await connection.receiveAll()
            let end = try #require(reply.firstRange(of: Array("\r\n\r\n".utf8)))
            let head = String(decoding: reply[..<end.lowerBound], as: UTF8.self)
            let status = Int(head.split(separator: " ")[1]) ?? 0
            lock.withLock {
                fetches.append(Fetch(status: status, body: Array(reply[end.upperBound...])))
            }
        } catch {
            lock.withLock { fetches.append(Fetch(status: 0, body: [])) }
        }
    }

    /// Stops answering: every connection from now on is refused.
    func vanish() {
        lock.withLock { vanished = true }
        server.stop()
    }
}

/// The text of the first `<name>` in `body`, unescaped once, as the renderer's XML parser
/// would give it.
private func argument(_ name: String, _ body: String) -> String {
    guard let start = body.range(of: "<\(name)>"),
        let end = body.range(of: "</\(name)>", range: start.upperBound..<body.endIndex)
    else { return "" }
    return String(body[start.upperBound..<end.lowerBound])
        .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(
            of: "&apos;", with: "'"
        )
        .replacingOccurrences(of: "&amp;", with: "&")
}

private func response(_ action: String, _ body: String) -> String {
    """
    <?xml version="1.0" encoding="utf-8"?>
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>
    <u:\(action)Response xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">\(body)\
    </u:\(action)Response></s:Body></s:Envelope>
    """
}

func ok(_ body: String) -> String {
    "HTTP/1.1 200 OK\r\nContent-Type: text/xml\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
}

private func fault(_ code: Int) -> String {
    let body = """
        <?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
        <s:Body><s:Fault><faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring>
        <detail><UPnPError xmlns="urn:schemas-upnp-org:control-1-0"><errorCode>\(code)</errorCode>
        <errorDescription>Refused</errorDescription></UPnPError></detail></s:Fault></s:Body>
        </s:Envelope>
        """
    return "HTTP/1.1 500 Internal Server Error\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
}
