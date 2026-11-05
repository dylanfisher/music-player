import Foundation
import LocalNetwork
import Network

/// The one TCP connection to the receiver's control port, in Denon's line protocol: a command
/// or status line is printable ASCII ending in a carriage return (ADR 0039).
///
/// Lines out are spaced `commandGapSeconds` apart, and `powerOnGapSeconds` after power on, as
/// the spec asks. A line equal to the last one waiting is dropped, so a held key moves the
/// volume a step per gap and stops when it's let go, and a volume level replaces a level still
/// waiting, so a dragged slider sends a level per gap and ends on the last. Lines in are cut at `lineCap` bytes
/// without a carriage return, past which the connection is dropped. A refused, failed or
/// closed connection ends it, and it never connects again on its own.
final class ReceiverConnection: @unchecked Sendable {
    static let port: UInt16 = 23
    /// Most bytes a line may have before its carriage return: the spec's message cap.
    static let lineCap = 135
    static let commandGapSeconds = 0.05
    static let powerOnGapSeconds = 1.0
    static let connectSeconds = 5.0
    /// Most lines that may wait to be sent.
    static let waitingCap = 16
    /// How long a connection may stay silent after it opens. A receiver answers `PW?` within
    /// 200 ms, the spec says; one that accepts and never answers has its control slot taken.
    static let firstLineSeconds = 1.0
    /// Most lines in any second. A receiver sends a few dozen on an input change; past this it's
    /// flooding, and the connection is dropped.
    static let linesPerSecondCap = 200

    /// What became of a line handed to `send`.
    enum Sending: Equatable {
        case queued
        /// `waitingCap` lines already wait.
        case full
        /// The connection has ended, or is ending.
        case ended
    }

    enum Update: Equatable {
        case connected
        /// A line in, without its carriage return.
        case line(ReceiverLine, text: String)
        case ended(End)
    }

    enum End: Error, Equatable, CustomStringConvertible {
        case refused(String)
        case dropped(String)
        case overlongLine
        case timedOut
        case silent
        case flooding

        var description: String {
            switch self {
            case .refused(let why): "it refused the connection (\(why))"
            case .dropped(let why): "the connection dropped (\(why))"
            case .overlongLine:
                "it sent over \(ReceiverConnection.lineCap) bytes without a line end, so the"
                    + " connection was dropped"
            case .timedOut: "it didn't answer within \(Int(ReceiverConnection.connectSeconds)) s"
            case .silent:
                "it took the connection but sent nothing; another app, such as HEOS or AVR"
                    + " Remote, may hold its one control connection"
            case .flooding:
                "it sent over \(ReceiverConnection.linesPerSecondCap) lines in a second, so the"
                    + " connection was dropped"
            }
        }
    }

    // Everything below is touched only on `queue`.
    private let queue = DispatchQueue(label: "ReceiverConnection")
    private let connection: NWConnection
    private let updates: @Sendable (Update) -> Void
    private let now: @Sendable () -> Double
    private var buffer: [UInt8] = []
    private var waiting: [[UInt8]] = []
    private var isReady = false
    private var isEnded = false
    private var isSending = false
    private var heardLine = false
    /// When each line in the last second came.
    private var recentLines: [Double] = []
    private var nextSendTime = 0.0
    /// When each line went out, for tests of the gaps.
    private var sendTimes: [Double] = []

    init(
        address: LocalNetwork.IPAddress, port: UInt16 = port,
        now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
        updates: @escaping @Sendable (Update) -> Void
    ) {
        connection = NWConnection(
            host: address.endpointHost, port: NWEndpoint.Port(rawValue: port)!,
            using: directTCP())
        self.updates = updates
        self.now = now
    }

    func start() {
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                isReady = true
                updates(.connected)
                receive()
                drain()
                queue.asyncAfter(deadline: .now() + Self.firstLineSeconds) { [self] in
                    if !heardLine { end(.silent) }
                }
            case .waiting(let error): end(.refused("\(error)"))
            case .failed(let error) where error == .posix(.ECONNREFUSED): end(.refused("\(error)"))
            case .failed(let error): end(.dropped("\(error)"))
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.connectSeconds) { [self] in
            if !isReady { end(.timedOut) }
        }
    }

    /// Queues `line` to go out after the lines before it. A repeat of the last waiting line is
    /// dropped quietly, and counts as queued; a volume level takes the place of a level waiting
    /// last.
    @discardableResult
    func send(_ line: [UInt8]) -> Sending {
        queue.sync {
            guard !isEnded else { return .ended }
            if waiting.last == line { return .queued }
            if let last = waiting.last, isVolumeLevel(last), isVolumeLevel(line) {
                waiting[waiting.count - 1] = line
                return .queued
            }
            guard waiting.count < Self.waitingCap else { return .full }
            waiting.append(line)
            drain()
            return .queued
        }
    }

    /// `MV` and a level's digits, as `ReceiverCommand.setVolume` sends; not `MVUP` or `MVDOWN`.
    private func isVolumeLevel(_ line: [UInt8]) -> Bool {
        line.count > 2 && line[0] == UInt8(ascii: "M") && line[1] == UInt8(ascii: "V")
            && (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(line[2])
    }

    /// Closes the connection without an update.
    func stop() {
        queue.sync {
            isEnded = true
            waiting = []
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
    }

    /// Sends the next waiting line once the gap since the last allows.
    private func drain() {
        guard isReady, !isEnded, !isSending, let line = waiting.first else { return }
        let wait = nextSendTime - now()
        guard wait <= 0 else {
            queue.asyncAfter(deadline: .now() + wait) { [self] in drain() }
            return
        }
        waiting.removeFirst()
        isSending = true
        let sentAt = now()
        sendTimes.append(sentAt)
        nextSendTime =
            sentAt
            + (line == ReceiverCommand.power(true).line
                ? Self.powerOnGapSeconds : Self.commandGapSeconds)
        connection.send(
            content: Data(line),
            completion: .contentProcessed { [self] error in
                isSending = false
                if let error {
                    end(.dropped("\(error)"))
                } else {
                    drain()
                }
            })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
            [self] data, _, isComplete, error in
            guard !isEnded else { return }
            for byte in data ?? Data() {
                switch byte {
                case UInt8(ascii: "\r"):
                    heardLine = true
                    let time = now()
                    recentLines.removeAll { time - $0 >= 1 }
                    recentLines.append(time)
                    guard recentLines.count <= Self.linesPerSecondCap else { return end(.flooding) }
                    updates(
                        .line(
                            ReceiverLine(buffer[...]), text: String(decoding: buffer, as: UTF8.self)
                        ))
                    buffer = []
                // Not in the protocol, but harmless: a receiver that ends lines in CR LF.
                case UInt8(ascii: "\n"):
                    continue
                default:
                    guard buffer.count < Self.lineCap else { return end(.overlongLine) }
                    buffer.append(byte)
                }
            }
            if let error {
                end(.dropped("\(error)"))
            } else if isComplete {
                end(.dropped("the receiver closed it"))
            } else {
                receive()
            }
        }
    }

    private func end(_ reason: End) {
        guard !isEnded else { return }
        isEnded = true
        waiting = []
        connection.stateUpdateHandler = nil
        connection.cancel()
        updates(.ended(reason))
    }

    /// Whether it bypasses any proxy, as everything on the LAN does.
    var bypassesProxies: Bool { connection.parameters.preferNoProxies }

    /// When each line went out so far.
    var sentTimes: [Double] { queue.sync { sendTimes } }
}
