import Darwin
import Foundation
import Testing

@testable import LocalSocket

/// Each test's server, in a temporary folder of its own, stopped and removed at the end.
private final class Fixture: @unchecked Sendable {
    let root: URL
    let path: String
    private let lock = NSLock()
    private var problemsSeen: [LocalSocketError] = []
    private var requestsSeen: [Data] = []

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ls-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        path = root.appendingPathComponent("scripting/socket").path
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var problems: [LocalSocketError] { lock.withLock { problemsSeen } }
    var requests: [Data] { lock.withLock { requestsSeen } }

    /// A server that answers each request with its bytes reversed.
    func server(allowedUID: uid_t = geteuid(), cap: Int = 64, timeout: Double = 0.3) throws
        -> LocalSocketServer
    {
        try LocalSocketServer(
            path: path, allowedUID: allowedUID, requestCap: cap, timeoutSeconds: timeout,
            problem: { [self] error in lock.withLock { problemsSeen.append(error) } },
            handler: { [self] request, reply in
                lock.withLock { requestsSeen.append(request) }
                try? reply.send(Data(request.reversed()))
            })
    }

    func exchange(_ text: String, serverUID: uid_t = geteuid()) throws -> String {
        let reply = try localSocketExchange(
            path: path, request: Data(text.utf8), replyCap: 64, timeoutSeconds: 2,
            serverUID: serverUID)
        return String(decoding: reply, as: UTF8.self)
    }

    /// Waits up to two seconds for a problem to be reported.
    func firstProblem() throws -> LocalSocketError {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let first = problems.first { return first }
            usleep(5000)
        }
        Issue.record("no problem reported; requests: \(requests)")
        throw LocalSocketError.timedOut
    }
}

/// A connected socket that sends whatever the test writes, for frames a real client wouldn't.
private func rawConnection(_ path: String) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    let address = try #require(socketAddress(path))
    let connected = withSocketAddress(address) { connect(fd, $0, $1) }
    try #require(connected == 0, "connect: \(errno)")
    return fd
}

private func mode(_ path: String) -> mode_t {
    var info = stat()
    lstat(path, &info)
    return info.st_mode & 0o777
}

@Suite struct LocalSocketServerTests {
    @Test func aRequestIsAnsweredOnASocketOnlyThisUserCanReach() throws {
        let fixture = try Fixture()
        let server = try fixture.server()
        defer { server.stop() }
        #expect(try fixture.exchange("abc") == "cba")
        #expect(mode(fixture.path) == 0o600)
        #expect(mode((fixture.path as NSString).deletingLastPathComponent) == 0o700)
        #expect(fixture.problems.isEmpty)
    }

    @Test func aPeerOfAnotherUserIsRefusedBeforeItsRequestIsRead() throws {
        let fixture = try Fixture()
        let server = try fixture.server(allowedUID: geteuid() + 1)
        defer { server.stop() }
        #expect(throws: LocalSocketError.closed) { try fixture.exchange("abc") }
        #expect(try fixture.firstProblem() == .otherUser(geteuid()))
        #expect(fixture.requests.isEmpty)
    }

    @Test func theClientRefusesAServerOfAnotherUser() throws {
        let fixture = try Fixture()
        let server = try fixture.server()
        defer { server.stop() }
        #expect(throws: LocalSocketError.otherUser(geteuid())) {
            try fixture.exchange("abc", serverUID: geteuid() + 1)
        }
    }

    @Test func anOversizedRequestIsRefusedUnreadAndTheNextIsServed() throws {
        let fixture = try Fixture()
        let server = try fixture.server(cap: 64)
        defer { server.stop() }
        let fd = try rawConnection(fixture.path)
        defer { close(fd) }
        let header: [UInt8] = [0, 0, 0, 65]
        #expect(write(fd, header, header.count) == header.count)
        #expect(try fixture.firstProblem() == .tooLarge(bytes: 65, cap: 64))
        #expect(fixture.requests.isEmpty)
        #expect(try fixture.exchange("next") == "txen")
    }

    @Test func aSlowRequestTimesOutAndTheNextIsServed() throws {
        let fixture = try Fixture()
        let server = try fixture.server(timeout: 0.3)
        defer { server.stop() }
        let fd = try rawConnection(fixture.path)
        defer { close(fd) }
        let partial: [UInt8] = [0, 0]
        #expect(write(fd, partial, partial.count) == partial.count)
        #expect(try fixture.exchange("next") == "txen")
        #expect(fixture.problems == [.timedOut])
        #expect(fixture.requests == [Data("next".utf8)])
    }

    @Test func aStaleSocketIsReplacedButALiveOneIsNot() throws {
        let fixture = try Fixture()
        let first = try fixture.server()
        #expect(throws: LocalSocketError.inUse(fixture.path)) { try fixture.server() }
        // A socket file with nothing behind it, as a crash leaves.
        first.stop()
        let stale = socket(AF_UNIX, SOCK_STREAM, 0)
        let address = try #require(socketAddress(fixture.path))
        #expect(withSocketAddress(address) { bind(stale, $0, $1) } == 0)
        close(stale)
        let second = try fixture.server()
        defer { second.stop() }
        #expect(try fixture.exchange("ok") == "ko")
    }

    @Test func somethingElseAtTheSocketsPathIsLeftAlone() throws {
        let fixture = try Fixture()
        try LocalSocketServer.prepareFolder((fixture.path as NSString).deletingLastPathComponent)
        try Data("mine".utf8).write(to: URL(fileURLWithPath: fixture.path))
        #expect(throws: LocalSocketError.notASocket(fixture.path)) { try fixture.server() }
        #expect(try String(contentsOfFile: fixture.path, encoding: .utf8) == "mine")
    }

    @Test func aFolderOpenToOthersOrALinkIsRefused() throws {
        let fixture = try Fixture()
        let folder = (fixture.path as NSString).deletingLastPathComponent
        #expect(mkdir(folder, 0o755) == 0)
        #expect(chmod(folder, 0o755) == 0)
        #expect(throws: LocalSocketError.self) { try fixture.server() }
        rmdir(folder)
        let elsewhere = fixture.root.appendingPathComponent("elsewhere").path
        #expect(mkdir(elsewhere, 0o700) == 0)
        #expect(symlink(elsewhere, folder) == 0)
        #expect(
            throws: LocalSocketError.unsafeFolder(
                folder, reason: "is a link or a file, not a folder")
        ) {
            try fixture.server()
        }
        #expect(!FileManager.default.fileExists(atPath: elsewhere + "/socket"))
    }

    @Test func aPathTooLongForASocketIsRefused() throws {
        let path = "/tmp/" + String(repeating: "x", count: 120)
        #expect(throws: LocalSocketError.pathTooLong(path)) {
            try LocalSocketServer(
                path: path, requestCap: 1, timeoutSeconds: 1, problem: { _ in },
                handler: { _, _ in })
        }
    }

    @Test func stopRemovesTheSocketAndNothingAnswers() throws {
        let fixture = try Fixture()
        try fixture.server().stop()
        #expect(!FileManager.default.fileExists(atPath: fixture.path))
        #expect(throws: LocalSocketError.notListening(fixture.path)) { try fixture.exchange("x") }
    }
}
