import Foundation

/// The code Settings → Remote shows, which a page trades for a token (ADR 0214): six digits,
/// live for `lifetimeSeconds` and dead after `missCap` wrong guesses, after which a new one has
/// to be shown. Guesses are compared in constant time. Its state is guarded by `lock`.
public final class RemotePairing: @unchecked Sendable {
    static let lifetimeSeconds = 120.0
    static let missCap = 5
    static let digits = 6

    /// What the pane shows.
    public enum Status: Equatable, Sendable {
        case live(code: String, secondsLeft: Double)
        /// No code was shown, or one expired or was guessed wrong too often.
        case none(reason: String?)
    }

    /// Why a trade failed, as the page is told.
    enum Refusal: Error, Equatable, CustomStringConvertible {
        case noCode
        case wrong

        var description: String {
            switch self {
            case .noCode: "no code is showing; open Settings → Remote on the Mac for one"
            case .wrong: "that isn't the code Settings → Remote shows"
            }
        }
    }

    private let lock = NSLock()
    private let now: @Sendable () -> Double
    private var code: [UInt8]?
    private var issued = 0.0
    private var misses = 0
    private var ended: String?

    public init(now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }) {
        self.now = now
    }

    /// Makes a new code, which replaces any other, and says it.
    @discardableResult
    public func newCode() -> String {
        var generator = SystemRandomNumberGenerator()
        let made = (0..<Self.digits).map { _ in
            UInt8(ascii: "0") + UInt8(generator.next(upperBound: UInt32(10)))
        }
        lock.withLock {
            code = made
            issued = now()
            misses = 0
            ended = nil
        }
        return String(decoding: made, as: UTF8.self)
    }

    /// Ends the code shown, as turning the remote off does.
    public func clear() {
        lock.withLock {
            code = nil
            ended = nil
        }
    }

    public var status: Status {
        lock.withLock {
            expireIfDue()
            guard let code else { return .none(reason: ended) }
            return .live(
                code: String(decoding: code, as: UTF8.self),
                secondsLeft: max(0, Self.lifetimeSeconds - (now() - issued)))
        }
    }

    /// Takes `guess` once: right, the code ends, so it pairs one device; wrong, it counts as a
    /// miss, and the last allowed miss ends it.
    func trade(_ guess: String) throws(Refusal) {
        lock.lock()
        defer { lock.unlock() }
        expireIfDue()
        guard let code else { throw .noCode }
        let bytes = Array(guess.utf8)
        guard bytes.count == code.count && constantTimeEqual(bytes, code) else {
            misses += 1
            if misses >= Self.missCap {
                self.code = nil
                ended = "\(Self.missCap) wrong codes were tried; show a new one"
            }
            throw .wrong
        }
        self.code = nil
        ended = nil
    }

    private func expireIfDue() {
        guard code != nil, now() - issued >= Self.lifetimeSeconds else { return }
        code = nil
        ended = "the code expired; show a new one"
    }
}

/// Whether `a` and `b`, of one length, hold the same bytes, taking as long whatever they hold.
func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
    precondition(a.count == b.count, "compared in constant time only at one length")
    var difference: UInt8 = 0
    for index in a.indices { difference |= a[index] ^ b[index] }
    return difference == 0
}
