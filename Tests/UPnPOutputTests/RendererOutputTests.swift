import Foundation
import Testing

@testable import Fixtures
@testable import LocalNetwork
@testable import Playback
@testable import UPnP
@testable import UPnPOutput

/// A made-up interface on 127/8, so the fake renderer at 127.0.0.1 counts as another device.
private let subnet = NetworkInterface(
    name: "lo9", index: 1, address: IPAddress("127.0.0.2")!, prefixLength: 8)
/// How often the output polls the fake renderer. Every poll opens connections, and 4 test
/// processes at 0.2 s used up the machine's ephemeral ports ("address in use") for seconds.
private let pollSeconds = 0.2
/// Where the output's server listens in tests: 127.0.0.2 can't be bound on macOS.
private let loopback = NetworkInterface(
    name: "lo0", index: 1, address: IPAddress("127.0.0.1")!, prefixLength: 8)

private struct FakeSSDP: SSDPTransport {
    var datagrams: [SSDPDatagram]

    func search(_ request: [UInt8], from interfaces: [NetworkInterface], seconds: Double)
        async throws(LocalNetworkError) -> [SSDPDatagram]
    {
        datagrams
    }
}

/// The renderer as discovery finds it from the fake's SSDP reply.
private func discovered(_ fake: FakeRenderer) async throws -> Renderer {
    let reply = SSDPDatagram(
        bytes: Array(
            ("HTTP/1.1 200 OK\r\nLOCATION: \(fake.location)\r\n"
                + "ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\nUSN: uuid:x\r\n\r\n").utf8),
        source: IPAddress("127.0.0.1")!)
    let outcome = try await RendererDiscovery.discover(
        transport: FakeSSDP(datagrams: [reply]), subnets: LocalSubnets([subnet]), seconds: 0.1)
    #expect(outcome.problems == [])
    return try #require(outcome.renderers.first)
}

/// Ten seconds of 16/44.1 silence in each container, made once per run.
private let audio: [String: URL] = {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
        "renderer-output-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let wav = folder.appendingPathComponent("silence.wav", isDirectory: false)
    try! writeWAV(at: wav, sampleRateHz: 44_100, bitsPerSample: 16, frames: 441_000) { _, _ in 0 }
    var files = ["wav": wav]
    for (name, arguments) in [
        ("flac", ["-f", "flac", "-d", "flac"]), ("m4a", ["-f", "m4af", "-d", "alac"]),
        ("aac", ["-f", "m4af", "-d", "aac"]),
        ("aiff", ["--no-filler", "-f", "AIFF", "-d", "BEI16"]),
    ] {
        let url = folder.appendingPathComponent("silence.\(name)", isDirectory: false)
        try! runAfconvert(arguments + [wav.path, url.path])
        files[name] = url
    }
    // One second of DSD64 silence; a tone would take a debug build seconds to make.
    let channels = [Data](repeating: Data(repeating: 0x69, count: 352_800), count: 2)
    files["dsf"] = folder.appendingPathComponent("tone.dsf", isDirectory: false)
    try! dsfFile(rateHz: 2_822_400, channels: channels).write(to: files["dsf"]!)
    files["dff"] = folder.appendingPathComponent("tone.dff", isDirectory: false)
    try! dffFile(rateHz: 2_822_400, channels: channels).write(to: files["dff"]!)
    // One second, for tests that play a track to its end by the app's clock.
    let short = folder.appendingPathComponent("short.wav", isDirectory: false)
    try! writeWAV(at: short, sampleRateHz: 44_100, bitsPerSample: 16, frames: 44_100) { _, _ in 0 }
    files["short"] = short
    let shortFLAC = folder.appendingPathComponent("short.flac", isDirectory: false)
    try! runAfconvert(["-f", "flac", "-d", "flac", short.path, shortFLAC.path])
    files["shortFLAC"] = shortFLAC
    // Five seconds: long enough for a stall well before the last seconds.
    let medium = folder.appendingPathComponent("medium.wav", isDirectory: false)
    try! writeWAV(at: medium, sampleRateHz: 44_100, bitsPerSample: 16, frames: 220_500) {
        _, _ in 0
    }
    files["medium"] = medium
    return files
}()

private func item(_ id: Int, _ kind: String = "flac") -> OutputItem {
    OutputItem(id: id, url: audio[kind]!)
}

/// What the output emitted, as it emits it.
private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    private var errors: [OutputItem.ID: String] = [:]

    init(_ output: RendererOutput) {
        Task {
            for await event in output.events { self.add(event) }
        }
    }

    private func add(_ event: OutputEvent) {
        lock.withLock {
            switch event {
            case .trackStarted(let id, _): events.append("started \(id)")
            case .trackEnded(let id): events.append("ended \(id)")
            case .finished(let id): events.append("finished \(id)")
            case .trackFailed(let id, let error):
                events.append("trackFailed \(id)")
                errors[id] = "\(error)"
            case .failed(let id, let error):
                events.append("failed \(id ?? -1)")
                errors[id ?? -1] = "\(error)"
            case .deviceLost(let id, _): events.append("lost \(id ?? -1)")
            case .deviceReturned: events.append("returned")
            case .seekFailed(let id, let seconds): events.append("seekFailed \(id) at \(seconds)")
            case .transportChanged(let id, let playing):
                events.append("\(playing ? "playing" : "paused") \(id)")
            case .formatChanged, .underrun: events.append("\(event)")
            }
        }
    }

    var all: [String] { lock.withLock { events } }
    func error(_ id: OutputItem.ID) -> String? { lock.withLock { errors[id] } }

    /// Waits up to `seconds` for `events` to have been emitted, in order, and fails with what
    /// came instead.
    func wait(for expected: [String], seconds: Double = 5) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if all.count >= expected.count, Array(all.prefix(expected.count)) == expected { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        Issue.record("waited for \(expected), got \(all)")
    }
}

/// Waits up to five seconds for `check`, and fails with `what` otherwise.
private func eventually(_ what: String, _ check: () -> Bool) async {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        if check() { return }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    Issue.record("timed out waiting for \(what)")
}

private func output(
    _ fake: FakeRenderer, timeout: Double = 1,
    rediscover: RendererOutput.Rediscover? = nil
) async throws -> (RendererOutput, EventLog) {
    let output = try RendererOutput(
        renderer: try await discovered(fake), serverInterface: loopback, pollSeconds: pollSeconds,
        timeoutSeconds: timeout, rediscover: rediscover)
    return (output, EventLog(output))
}

@Test func discoveryReadsTheCapturedDenonAndSonos() async throws {
    let denon = try await discovered(try await FakeRenderer.denon())
    #expect(denon.name == "Denon AVR-X1800H")
    #expect(denon.udn == "uuid:00000000-0000-4000-8000-000000000002")
    #expect(denon.isDenonReceiver)
    #expect(denon.transport?.control.target == "/upnp/control/renderer_dvc/AVTransport")
    #expect(denon.transport?.description?.target == "/upnp/scpd/renderer_dvc/AVTransport.xml")
    #expect(
        denon.httpAudioTypes == [
            "audio/mpeg", "audio/vnd.dlna.adts", "audio/x-ms-wma", "audio/l16", "audio/wav",
            "audio/mp3", "audio/flac", "audio/aac", "audio/m4a", "audio/dsd", "audio/dsf",
            "audio/dff", "audio/x-dsd", "audio/x-dsf", "audio/x-dff",
        ])
    let sonos = try await discovered(try await FakeRenderer.sonos())
    #expect(!sonos.isDenonReceiver)
    #expect(sonos.transport?.control.target == "/MediaRenderer/AVTransport/Control")
}

@Test func theSettingsRendererIsFoundByUDNOrTheOnesFoundAreNamed() async throws {
    let denon = try await discovered(try await FakeRenderer.denon())
    let sonos = try await discovered(try await FakeRenderer.sonos())
    #expect(try RendererChoice.renderer(denon.udn, in: [sonos, denon]) == denon)
    #expect {
        try RendererChoice.renderer("uuid:gone", in: [sonos, denon])
    } throws: { error in
        "\(error)"
            == "no renderer uuid:gone answered on the local network; these did:"
            + " Test Room - Sonos Era 100 Media Renderer - RINCON_00005E00530101400"
            + " (uuid:RINCON_00005E00530101400_MR), Denon AVR-X1800H"
            + " (uuid:00000000-0000-4000-8000-000000000002)"
    }
    let report = RendererChoice.report([denon])
    #expect(
        report
            == "UPnP renderers, by the UDN output.renderer takes:\n  Denon AVR-X1800H"
            + " (Denon AVR-X1800H) at 127.0.0.1, uuid:00000000-0000-4000-8000-000000000002: takes"
            + " audio/mpeg, audio/vnd.dlna.adts, audio/x-ms-wma, audio/l16, audio/wav, audio/mp3,"
            + " audio/flac, audio/aac, audio/m4a, audio/dsd, audio/dsf, audio/dff, audio/x-dsd,"
            + " audio/x-dsf, audio/x-dff")
    #expect(RendererChoice.report([]) == "No UPnP renderers answered on the local network.")
}

@Test func eachContainerIsOfferedAsATypeTheRendererLists() async throws {
    let denon = try await discovered(try await FakeRenderer.denon())
    let sonos = try await discovered(try await FakeRenderer.sonos())
    #expect(try RendererTrack.read(audio["flac"]!, for: denon).contentType == "audio/flac")
    #expect(try RendererTrack.read(audio["wav"]!, for: denon).contentType == "audio/wav")
    // The Denon lists no audio/mp4. AAC goes as audio/m4a, the type it lists for MP4; ALAC
    // under it couldn't be decoded at the receiver, so ALAC is reported there, as AIFF is.
    #expect(try RendererTrack.read(audio["aac"]!, for: denon).contentType == "audio/m4a")
    #expect {
        try RendererTrack.read(audio["m4a"]!, for: denon)
    } throws: { error in
        "\(error)".hasPrefix("Denon AVR-X1800H doesn't take MP4 (ALAC) files")
    }
    #expect(try RendererTrack.read(audio["m4a"]!, for: sonos).contentType == "audio/mp4")
    #expect(try RendererTrack.read(audio["aac"]!, for: sonos).contentType == "audio/mp4")
    #expect(try RendererTrack.read(audio["aiff"]!, for: sonos).contentType == "audio/aiff")
    let flac = try RendererTrack.read(audio["flac"]!, for: denon)
    #expect(flac.durationSeconds == 10)
    #expect(flac.metadata.protocolInfo == "http-get:*:audio/flac:*")
    #expect(flac.metadata.title == "silence")
    #expect(flac.signal.bitsPerChannel == 16 && flac.signal.sampleRateHz == 44_100)
    // The Denon lists no AIFF type at all, so AIFF is reported, not transcoded.
    #expect {
        try RendererTrack.read(audio["aiff"]!, for: denon)
    } throws: { error in
        "\(error)".hasPrefix("Denon AVR-X1800H doesn't take AIFF (PCM) files; it takes audio/mpeg")
    }
}

@Test func dsdGoesUnchangedUnderTheDSDTypeTheRendererListsAndIsRefusedElsewhere() async throws {
    let denon = try await discovered(try await FakeRenderer.denon())
    let dsf = try RendererTrack.read(audio["dsf"]!, for: denon)
    #expect(dsf.contentType == "audio/dsf")
    #expect(dsf.metadata.protocolInfo == "http-get:*:audio/dsf:*")
    #expect(dsf.durationSeconds == 1)
    #expect(dsf.signal.formatID == dsdFormatID && dsf.signal.sampleRateHz == 2_822_400)
    #expect(try RendererTrack.read(audio["dff"]!, for: denon).contentType == "audio/dff")
    let sonos = try await discovered(try await FakeRenderer.sonos())
    #expect {
        try RendererTrack.read(audio["dsf"]!, for: sonos)
    } throws: { error in
        "\(error)".hasPrefix(
            "Test Room - Sonos Era 100 Media Renderer - RINCON_00005E00530101400 doesn't take DSF (DSD) files"
        )
    }
}

@Test func aTrackPlaysFromTheServerWithItsMetadata() async throws {
    let fake = try await FakeRenderer.denon()
    let (output, log) = try await output(fake)
    defer { output.close() }
    output.load(item(1), startSeconds: 0, playing: true)
    await log.wait(for: ["started 1"])
    #expect(fake.commands == ["SetAVTransportURI", "Play"])
    #expect(fake.transportState == .playing)
    let metadata = try #require(fake.lastMetadata)
    #expect(metadata.contains("protocolInfo=\"http-get:*:audio/flac:*\""))
    #expect(metadata.contains("<dc:title>silence</dc:title>"))
    #expect(metadata.contains("duration=\"0:00:10.000\""))
    // The renderer fetched the file's own first 100 bytes, by token.
    let flac = Array(try Data(contentsOf: audio["flac"]!).prefix(100))
    #expect(fake.fetched == [FakeRenderer.Fetch(status: 206, body: flac)])
    #expect(fake.currentURI.hasPrefix("http://127.0.0.1:"))
    #expect(!fake.currentURI.contains("silence"))
    await eventually("the position to move") { (output.position()?.seconds ?? 0) > 0.1 }
    #expect(output.position()?.item == 1)
}

@Test func pauseSeekAndPlayGoToTheRenderer() async throws {
    let fake = try await FakeRenderer.denon()
    let (output, log) = try await output(fake)
    defer { output.close() }
    output.load(item(1), startSeconds: 0, playing: true)
    await log.wait(for: ["started 1"])
    await eventually("the renderer to be seen playing") {
        fake.actions.contains("GetTransportInfo")
    }
    output.pause()
    await eventually("a pause") { fake.transportState == .paused }
    output.seek(toSeconds: 5)
    await eventually("a seek") { fake.actions.contains("Seek") }
    await eventually("the position to be the seek's") { output.position()?.seconds == 5 }
    #expect(abs(fake.playedSeconds - 5) < 0.01)
    output.play()
    await eventually("play again") { fake.transportState == .playing }
    output.stop()
    await eventually("a stop") { fake.actions.last == "Stop" }
    await eventually("nothing loaded") { output.position() == nil }
}

@Test func aLoadPartwayInSeeksOnceTheRendererPlays() async throws {
    let fake = try await FakeRenderer.denon()
    let (output, log) = try await output(fake)
    defer { output.close() }
    output.load(item(1), startSeconds: 7, playing: true)
    await log.wait(for: ["started 1"])
    #expect(output.position()?.seconds == 7)
    await eventually("the seek") { fake.actions.contains("Seek") }
    #expect(fake.playedSeconds >= 7)
}

@Test func theNextTrackGoesOverWithSetNextAndPlaysWithoutAStop() async throws {
    let fake = try await FakeRenderer.denon(trackSeconds: 0.4)
    let (output, log) = try await output(fake)
    defer { output.close() }
    var paths = output.signalPaths.makeAsyncIterator()
    output.load(item(1), startSeconds: 0, playing: true)
    output.setNext(item(2))
    await log.wait(for: ["started 1", "ended 1", "started 2"])
    #expect(
        Array(fake.commands.prefix(3)) == [
            "SetAVTransportURI", "Play", "SetNextAVTransportURI",
        ])
    #expect(fake.actions.filter { $0 == "SetAVTransportURI" }.count == 1)
    var gapless: RendererGapless?
    while gapless != .nextURI, let path = await paths.next() {
        if case .renderer(let sink) = path.sink { gapless = sink.gapless }
    }
    // With nothing after it, the second track plays out and the output finishes.
    await log.wait(for: ["started 1", "ended 1", "started 2", "ended 2", "finished 2"])
    await eventually("nothing loaded") { output.position() == nil }
}

@Test func withoutSetNextTheNextTrackStartsAfterTheStop() async throws {
    let scpd = try captured("denon-avtransport-scpd.xml").replacingOccurrences(
        of: "<name>SetNextAVTransportURI</name>", with: "<name>Unlisted</name>")
    let fake = try await FakeRenderer.denon(trackSeconds: 0.4, scpd: scpd)
    let (output, log) = try await output(fake)
    defer { output.close() }
    output.load(item(1), startSeconds: 0, playing: true)
    output.setNext(item(2))
    await log.wait(for: ["started 1", "ended 1", "started 2"])
    #expect(!fake.actions.contains("SetNextAVTransportURI"))
    // The second track went with set-URI and Play, only once the first had stopped.
    #expect(fake.commands == ["SetAVTransportURI", "Play", "SetAVTransportURI", "Play"])
    let sets = fake.setTransportURIs
    #expect(sets.count == 2)
    #expect(sets.map(\.stateBefore) == [.stopped, .stopped])
    #expect(sets.first?.uri != sets.last?.uri)
    #expect(fake.currentURI == sets.last?.uri)
    var gapless: RendererGapless?
    for await path in output.signalPaths {
        if case .renderer(let sink) = path.sink, sink.contentType != nil {
            gapless = sink.gapless
            if case .afterStop = sink.gapless { break }
        }
    }
    #expect(gapless == .afterStop("its AVTransport has no SetNextAVTransportURI"))
}

@Test func aRendererThatStopsInsteadOfTakingTheNextTrackGetsItOnTheAppsClock() async throws {
    let fake = try await FakeRenderer.denon(trackSeconds: 1)
    fake.ignoresNext()
    let (output, log) = try await output(fake)
    defer { output.close() }
    let started = ProcessInfo.processInfo.systemUptime
    output.load(item(1, "short"), startSeconds: 0, playing: true)
    output.setNext(item(2))
    await log.wait(for: ["started 1", "ended 1", "started 2"], seconds: 8)
    // Given the next track, a stop isn't acted on at once: the app waits out the track's
    // length and its margin, then sends the next track itself.
    #expect(ProcessInfo.processInfo.systemUptime - started >= 2.5)
    #expect(fake.commands.filter { $0 == "SetAVTransportURI" }.count == 2)
}

@Test func aRendererThatStallsMidTrackIsWaitedForNotCutShort() async throws {
    let fake = try await FakeRenderer.denon(trackSeconds: 5)
    fake.ignoresNext()
    let (output, log) = try await output(fake)
    defer { output.close() }
    output.load(item(1, "medium"), startSeconds: 0, playing: true)
    output.setNext(item(2))
    await log.wait(for: ["started 1"])
    await eventually("the renderer to be seen playing") { fake.playedSeconds > 0.2 }
    // Re-buffering for three seconds puts it past the clock's first idea of the end.
    fake.stall(forSeconds: 3)
    await log.wait(for: ["started 1", "ended 1", "started 2"], seconds: 15)
    // The next track came only once the first had played out and stopped.
    #expect(fake.setTransportURIs.map(\.stateBefore) == [.stopped, .stopped])
}

@Test func aRendererStuckAtTheEndIsMovedOnByTheApp() async throws {
    let fake = try await FakeRenderer.denon(trackSeconds: 1)
    fake.ignoresNext()
    fake.hangsAtEnd()
    let (output, log) = try await output(fake)
    defer { output.close() }
    output.load(item(1, "short"), startSeconds: 0, playing: true)
    output.setNext(item(2))
    await log.wait(for: ["started 1"])
    let started = ProcessInfo.processInfo.systemUptime
    // It reports playing at the end forever; the app's clock ends the track, a one-second
    // track plus the lead margin after it started. A busy machine only makes it later, so
    // the wait's limit is the upper bound.
    await log.wait(for: ["started 1", "ended 1", "started 2"], seconds: 15)
    let took = ProcessInfo.processInfo.systemUptime - started
    #expect(took >= 2.5, "\(took) s")
    #expect(fake.commands.suffix(2) == ["SetAVTransportURI", "Play"])
}

@Test func aRendererBufferingAheadNeverFetchesADeadURL() async throws {
    let fake = try await FakeRenderer.denon(trackSeconds: 1)
    fake.buffersAhead()
    let (output, log) = try await output(fake)
    defer { output.close() }
    output.load(item(1, "short"), startSeconds: 0, playing: true)
    output.setNext(item(2, "shortFLAC"))
    await log.wait(for: ["started 1", "ended 1", "started 2"], seconds: 8)
    // The engine hands over the track after next as soon as the second starts.
    output.setNext(item(3, "short"))
    // Past the second track's real switch, when the renderer fetches the first track's end.
    await eventually("the switch's fetches") { fake.fetched.count >= 5 }
    #expect(fake.fetched.map(\.status) == [206, 206, 206, 206, 206])
    // One SetNext per next track, and nothing set over what the renderer buffered.
    #expect(fake.commands.filter { $0 == "SetNextAVTransportURI" }.count == 2)
    #expect(fake.commands.filter { $0 == "SetAVTransportURI" }.count == 1)
}

@Test func aNextTrackReplacedAfterTheRendererBufferedItStillServes() async throws {
    let fake = try await FakeRenderer.denon(trackSeconds: 1)
    fake.buffersAhead()
    fake.keepsFirstNext()
    let (output, log) = try await output(fake)
    defer { output.close() }
    output.load(item(1, "short"), startSeconds: 0, playing: true)
    output.setNext(item(2, "shortFLAC"))
    await eventually("the next track buffered") { fake.fetched.count >= 2 }
    output.setNext(item(3, "short"))
    // The renderer goes on to the track it buffered; its token still serves.
    await log.wait(for: ["started 1", "ended 1"], seconds: 8)
    await eventually("the switch's fetches") { fake.fetched.count >= 4 }
    #expect(fake.fetched.allSatisfy { $0.status == 206 }, "\(fake.fetched.map(\.status))")
}

@Test func aRendererThatVanishesMidTrackIsLostWhereItWas() async throws {
    let fake = try await FakeRenderer.denon()
    let (output, log) = try await output(fake, timeout: 0.3)
    defer { output.close() }
    output.load(item(1), startSeconds: 0, playing: true)
    await log.wait(for: ["started 1"])
    await eventually("a second's play") { fake.playedSeconds > 0.3 }
    fake.vanish()
    await log.wait(for: ["started 1", "lost 1"])
    await eventually("nothing loaded") { output.position() == nil }
}

@Test func stoppingARendererThatsGoneDoesntReportItLost() async throws {
    let fake = try await FakeRenderer.denon()
    let (output, log) = try await output(fake, timeout: 0.3)
    defer { output.close() }
    output.load(item(1), startSeconds: 0, playing: true)
    await log.wait(for: ["started 1"])
    fake.vanish()
    output.stop()
    await eventually("nothing loaded") { output.position() == nil }
    // Past the polls that would have lost it, had it still been loaded.
    try await Task.sleep(nanoseconds: 1_500_000_000)
    #expect(log.all == ["started 1"])
}

@Test func aRendererThatStallsIsLostAndNothingWaitsOnIt() async throws {
    let fake = try await FakeRenderer.denon()
    let (output, log) = try await output(fake, timeout: 0.3)
    defer { output.close() }
    output.load(item(1), startSeconds: 0, playing: true)
    await log.wait(for: ["started 1"])
    fake.stall("GetTransportInfo")
    // Every call returns at once while the renderer says nothing.
    let started = ProcessInfo.processInfo.systemUptime
    for _ in 0..<50 {
        output.pause()
        output.play()
        _ = output.position()
    }
    #expect(ProcessInfo.processInfo.systemUptime - started < 0.1)
    await log.wait(for: ["started 1", "lost 1"], seconds: 10)
}

@Test func aRefusedTrackIsReportedAndFinished() async throws {
    let fake = try await FakeRenderer.denon()
    fake.refuse("SetAVTransportURI", code: 714)
    let (output, log) = try await output(fake)
    defer { output.close() }
    output.load(item(1), startSeconds: 0, playing: true)
    await log.wait(for: ["trackFailed 1", "finished 1"])
    #expect(log.error(1)?.contains("UPnP error 714 (Refused)") == true)
}

@Test func anUnsupportedFormatIsReportedWithoutTouchingTheRenderer() async throws {
    let fake = try await FakeRenderer.denon()
    let (output, log) = try await output(fake)
    defer { output.close() }
    output.load(item(1, "aiff"), startSeconds: 0, playing: true)
    await log.wait(for: ["trackFailed 1", "finished 1"])
    #expect(log.error(1)?.contains("doesn't take AIFF (PCM) files") == true)
    #expect(fake.actions == [])
}

@Test func aTrackTheRendererNeverStartsIsReported() async throws {
    let fake = try await FakeRenderer.denon()
    fake.neverStarts()
    let (output, log) = try await output(fake)
    defer { output.close() }
    output.load(item(1), startSeconds: 0, playing: true)
    await log.wait(for: ["started 1", "trackFailed 1", "finished 1"])
    #expect(log.error(1)?.contains("may not decode audio/flac") == true)
}

@Test func playbackStoppedOrReplacedOnTheRendererEndsIt() async throws {
    let fake = try await FakeRenderer.denon()
    let (output, log) = try await output(fake)
    defer { output.close() }
    output.load(item(1), startSeconds: 0, playing: true)
    await log.wait(for: ["started 1"])
    await eventually("the renderer to be seen playing") { fake.playedSeconds > 0.6 }
    fake.stopOnItsOwn()
    await log.wait(for: ["started 1", "failed 1"])
    #expect(log.error(1) == "playback was stopped on Denon AVR-X1800H")

    output.load(item(2), startSeconds: 0, playing: true)
    await log.wait(for: ["started 1", "failed 1", "started 2"])
    fake.playOther()
    await log.wait(for: ["started 1", "failed 1", "started 2", "failed 2"])
}

@Test func aReplacedTrackServesForItsGraceAndNothingOnceStopped() async throws {
    let fake = try await FakeRenderer.denon()
    let (output, log) = try await output(fake)
    defer { output.close() }
    output.load(item(1), startSeconds: 0, playing: true)
    await log.wait(for: ["started 1"])
    let first = fake.currentURI
    output.load(item(2, "wav"), startSeconds: 0, playing: true)
    await log.wait(for: ["started 1", "started 2"])
    #expect(fake.fetched.map(\.status) == [206, 206])
    let url = try #require(URL(string: first))
    let port = try #require(url.port)
    // A renderer may still be reading the end of what it played.
    let replaced = try await get(url.path, port: port)
    #expect(replaced.hasPrefix("HTTP/1.1 200"))
    output.stop()
    await eventually("a stop") { fake.actions.last == "Stop" }
    let afterStop = await stoppedServing(url.path, port: port)
    #expect(afterStop)
}

@Test func closingEndsTheEventsAtOnce() async throws {
    let fake = try await FakeRenderer.denon()
    fake.stall("Stop")
    let (output, log) = try await output(fake)
    output.load(item(1), startSeconds: 0, playing: true)
    await log.wait(for: ["started 1"])
    let started = ProcessInfo.processInfo.systemUptime
    output.close()
    #expect(ProcessInfo.processInfo.systemUptime - started < 0.1)
    var after = 0
    for await _ in output.events { after += 1 }
    #expect(after == 0)
    output.close()
}

@Test func thePathSaysTheRendererDecodesAndTheReceiverSetsTheVolume() async throws {
    let fake = try await FakeRenderer.denon()
    let (output, log) = try await output(fake)
    defer { output.close() }
    output.load(item(1), startSeconds: 0, playing: true)
    await log.wait(for: ["started 1"])
    var found: SignalPath?
    for await path in output.signalPaths where path.track != nil {
        found = path
        break
    }
    let path = try #require(found)
    #expect(signalVerdict(path) == .unverifiable)
    guard case .renderer(let sink) = path.sink else {
        Issue.record("not a renderer: \(path.sink)")
        return
    }
    #expect(sink.contentType == "audio/flac")
    #expect(sink.volumeIsReceivers)
    #expect(sink.gapless == .nextURI)
    #expect(!output.hasVolume)
}

@Test func aNextTrackChangedInTheLastSecondIsPlayedInsteadOfTheOneTheRendererKept() async throws {
    let fake = try await FakeRenderer.denon(trackSeconds: 1)
    fake.keepsFirstNext()
    let (output, log) = try await output(fake)
    defer { output.close() }
    output.load(item(1), startSeconds: 0, playing: true)
    output.setNext(item(2))
    await eventually("the next track handed over") { fake.nextTrackURI != "" }
    let kept = fake.nextTrackURI
    // In the track's last second the queue changes; the renderer keeps what it had.
    await eventually("the last second") { fake.playedSeconds > 0.4 }
    output.setNext(item(3, "wav"))
    await log.wait(for: ["started 1", "ended 1", "started 3"])
    #expect(!log.all.contains("failed 1"))
    #expect(fake.setTransportURIs.count == 2)
    #expect(fake.setTransportURIs.last?.uri != kept)
    #expect(fake.currentURI == fake.setTransportURIs.last?.uri)
}

@Test func aURITheRendererReencodesIsStillTheTrack() async throws {
    let fake = try await FakeRenderer.denon(trackSeconds: 0.6)
    fake.reencodesURIs()
    let (output, log) = try await output(fake)
    defer { output.close() }
    output.load(item(1), startSeconds: 0, playing: true)
    output.setNext(item(2))
    await log.wait(for: ["started 1", "ended 1", "started 2"])
    #expect(!log.all.contains { $0.hasPrefix("failed") })
    #expect(sameURI("http://127.0.0.1:80/abc", "HTTP://127.0.0.1/%61bc"))
    #expect(!sameURI("http://127.0.0.1/abc", "http://127.0.0.2/abc"))
}

@Test func aRefusedSeekTellsTheEngineWherePlaybackStayed() async throws {
    let fake = try await FakeRenderer.denon()
    fake.refuse("Seek", code: 711)
    let (output, log) = try await output(fake)
    defer { output.close() }
    output.load(item(1), startSeconds: 0, playing: true)
    await log.wait(for: ["started 1"])
    await eventually("the renderer to be seen playing") { fake.playedSeconds > 0.3 }
    await eventually("a poll") { output.position()?.seconds ?? 0 > 0 }
    output.seek(toSeconds: 8)
    await eventually("the refusal") { log.all.contains { $0.hasPrefix("seekFailed 1") } }
    #expect((output.position()?.seconds ?? 99) < 5)
}

@Test func aSeekWhilePausedShowsAtOnceThoughTheRendererReportsTheOldPlace() async throws {
    let fake = try await FakeRenderer.denon()
    fake.reportsStalePositionWhilePaused()
    let (output, log) = try await output(fake)
    defer { output.close() }
    output.load(item(1), startSeconds: 0, playing: true)
    await log.wait(for: ["started 1"])
    await eventually("the renderer to be seen playing") {
        fake.actions.contains("GetTransportInfo")
    }
    output.pause()
    await eventually("a pause") { fake.transportState == .paused }
    output.seek(toSeconds: 6)
    await eventually("the seek") { output.position()?.seconds == 6 }
    // Polls go on reporting where it paused; the position shown stays where it went.
    let polls = fake.actions.filter { $0 == "GetPositionInfo" }.count
    await eventually("two more polls") {
        fake.actions.filter { $0 == "GetPositionInfo" }.count >= polls + 2
    }
    #expect(output.position()?.seconds == 6)
}

@Test func aSeekReportsItsTargetWhileTheRendererIsAsked() async throws {
    let fake = try await FakeRenderer.denon()
    let (output, log) = try await output(fake)
    defer { output.close() }
    output.load(item(1), startSeconds: 0, playing: true)
    await log.wait(for: ["started 1"])
    await eventually("a poll") { output.position()?.seconds ?? 0 > 0 }
    fake.stall("Seek")
    output.seek(toSeconds: 8)
    #expect(output.position()?.seconds == 8)
    await eventually("the seek sent") { fake.actions.contains("Seek") }
    try await Task.sleep(nanoseconds: 300_000_000)
    #expect(output.position()?.seconds == 8)
    // The file is ten seconds long; the seek goes to just short of its end, and so does the
    // position reported meanwhile.
    output.seek(toSeconds: 500)
    #expect(output.position()?.seconds == 9)
}

@Test func aSeekPastTheEndLandsJustShortOfIt() async throws {
    let fake = try await FakeRenderer.denon()
    let (output, log) = try await output(fake)
    defer { output.close() }
    output.load(item(1), startSeconds: 0, playing: true)
    await log.wait(for: ["started 1"])
    await eventually("the renderer to be seen playing") {
        fake.actions.contains("GetTransportInfo")
    }
    output.pause()
    await eventually("a pause") { fake.transportState == .paused }
    output.seek(toSeconds: 500)
    await eventually("a seek") { fake.actions.contains("Seek") }
    // The file is ten seconds long; a seek to its very end would stop it.
    #expect(abs(fake.playedSeconds - 9) < 0.01)
    #expect(fake.transportState == .paused)
}

@Test func aPauseGivenWhileTheRendererStartsIsSentOnceItPlays() async throws {
    let fake = try await FakeRenderer.denon()
    let (output, log) = try await output(fake)
    defer { output.close() }
    output.load(item(1), startSeconds: 0, playing: true)
    // Before any poll has seen it playing.
    output.pause()
    await log.wait(for: ["started 1"])
    await eventually("the queued pause") { fake.transportState == .paused }
    #expect(fake.commands == ["SetAVTransportURI", "Play", "Pause"])
    #expect(!log.all.contains { $0.hasPrefix("playing") || $0.hasPrefix("paused") })
}

@Test func aPauseOnTheRenderersOwnRemoteReachesTheEngine() async throws {
    let fake = try await FakeRenderer.denon()
    let (output, log) = try await output(fake)
    defer { output.close() }
    output.load(item(1), startSeconds: 0, playing: true)
    await log.wait(for: ["started 1"])
    await eventually("the renderer to be seen playing") { fake.playedSeconds > 0.3 }
    fake.pauseOnItsOwn()
    await log.wait(for: ["started 1", "paused 1"])
    // Nothing sends it back to playing: the engine follows the renderer.
    #expect(fake.commands.filter { $0 == "Play" }.count == 1)
}

@Test func aRendererThatAnswersAgainIsReportedBackAndPollingStops() async throws {
    let fake = try await FakeRenderer.denon()
    let (output, log) = try await output(fake, timeout: 0.3)
    defer { output.close() }
    output.load(item(1), startSeconds: 0, playing: true)
    await log.wait(for: ["started 1"])
    fake.stall("GetTransportInfo")
    await log.wait(for: ["started 1", "lost 1"], seconds: 10)
    #expect(output.isPolling)
    fake.answersAgain()
    await log.wait(for: ["started 1", "lost 1", "returned"], seconds: 10)
    await eventually("polling to stop") { !output.isPolling }
    let polls = fake.actions.count
    try await Task.sleep(nanoseconds: 1_000_000_000)
    #expect(fake.actions.count == polls)
}

@Test func nothingPollsOnceStopped() async throws {
    let fake = try await FakeRenderer.denon()
    let (output, log) = try await output(fake)
    defer { output.close() }
    #expect(!output.isPolling)
    output.load(item(1), startSeconds: 0, playing: true)
    await log.wait(for: ["started 1"])
    #expect(output.isPolling)
    output.stop()
    await eventually("polling to stop") { !output.isPolling }
}

@Test func aRendererThatMovedIsFoundAgainByItsUDN() async throws {
    let first = try await FakeRenderer.denon()
    let moved = try await FakeRenderer.denon()
    let movedRenderer = try await discovered(moved)
    let (output, log) = try await output(first, timeout: 0.3) { [movedRenderer] in
        [movedRenderer]
    }
    defer { output.close() }
    output.load(item(1), startSeconds: 0, playing: true)
    await log.wait(for: ["started 1"])
    first.vanish()
    await log.wait(for: ["started 1", "lost 1"], seconds: 10)
    // The engine loads again when the owner presses Play; the search finds it moved.
    output.load(item(2), startSeconds: 4, playing: true)
    await log.wait(for: ["started 1", "lost 1", "started 2"])
    #expect(moved.commands.prefix(2) == ["SetAVTransportURI", "Play"])
    await eventually("the moved renderer's fetch") { !moved.fetched.isEmpty }
    #expect(moved.fetched.map(\.status) == [206], "\(moved.fetched.map(\.status)) \(moved.actions)")
}

@Test func aFailedNetworkSearchStillListsAndSaysWhy() {
    struct Down: Error, CustomStringConvertible { var description: String { "no interfaces" } }
    #expect(
        RendererChoice.listing(.failure(Down()))
            == "The network search for UPnP renderers failed: no interfaces")
    #expect(
        RendererChoice.listing(.success([])) == "No UPnP renderers answered on the local network.")
}

@Test func anAIFFTheDenonCantTakeReachesTheNowPlayingMessage() async throws {
    let fake = try await FakeRenderer.denon()
    // The engine reads the events itself, so no log shares them.
    let output = try RendererOutput(
        renderer: try await discovered(fake), serverInterface: loopback, pollSeconds: pollSeconds,
        timeoutSeconds: 1)
    defer { output.close() }
    let engine = PlaybackEngine(output: output)
    let updates = await engine.updates()
    await engine.setQueue([audio["aiff"]!])
    await engine.play()
    var reason: String?
    for await update in updates {
        if case .trackFailed(_, let why) = update.event { reason = why }
        if update.event == .finished { break }
    }
    // NowPlayingModel shows a trackFailed as "Couldn't play <file>: <reason>".
    #expect(
        reason?.hasPrefix("Denon AVR-X1800H doesn't take AIFF (PCM) files") == true,
        "\(String(describing: reason))")
}

/// The head and body `GET path` gets from the server at `port`.
private func get(_ path: String, port: Int) async throws -> String {
    let connection = try await LoopbackConnection.connect(port: UInt16(port))
    defer { connection.close() }
    try await connection.send("GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n")
    return String(decoding: try await connection.receiveAll(), as: UTF8.self)
}

/// Whether the server that was at `port` has stopped serving `path`, within a second: the
/// connection is refused, or another process's server took the freed port and answers
/// something else.
private func stoppedServing(_ path: String, port: Int) async -> Bool {
    let deadline = Date().addingTimeInterval(1)
    while Date() < deadline {
        guard let reply = try? await get(path, port: port) else { return true }
        if !reply.hasPrefix("HTTP/1.1 200") { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return false
}
