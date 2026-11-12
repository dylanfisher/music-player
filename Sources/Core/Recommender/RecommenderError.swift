import DisplayText
import Foundation
import LocalNetwork

/// Why a call to music-recommender failed, naming the address it went to and never the token.
package struct RecommenderError: Error, Equatable, CustomStringConvertible {
    package enum Kind: Error, Equatable, CustomStringConvertible {
        /// `recommender.address` isn't another device's address on a local subnet.
        case offSubnet
        /// Nothing answered, the connection failed, or no answer came in time.
        case unreachable(LocalNetworkError)
        case cancelled
        /// A 401: no token, or the wrong one.
        case unauthorized
        /// A 400: the request wasn't of the route's shape (`bad_request`), or was over a cap
        /// (`too_large`).
        case badRequest(code: String, message: String)
        /// A 500 `internal`: the service failed answering, with its message, which says what
        /// failed and, for a profile kept, that it was kept.
        case failed(message: String)
        /// Another status than 200, 400, 401 or a 500 `internal`, with the code its body gave,
        /// if any.
        case status(Int, code: String?)
        /// A 200 with `ok: false`: the service understood the request and refused it.
        case refused(ServiceRefusal)
        /// A reply over the client's cap.
        case tooLarge(cap: Int)
        /// A reply that isn't valid HTTP, or isn't the route's JSON.
        case unreadable(String)
        /// A job in a state this player doesn't know, which is shown as an error, never skipped.
        case unknownState(String)

        init(_ error: LocalNetworkError) {
            switch error {
            case .refused, .failed, .timedOut, .system: self = .unreachable(error)
            case .cancelled: self = .cancelled
            case .tooLarge(let cap): self = .tooLarge(cap: cap)
            case .malformed: self = .unreadable("\(error)")
            case .status(let status): self = .status(status, code: nil)
            case .statusReply(let status, let raw): self = .init(status: status, raw: raw)
            }
        }

        /// A reply that isn't 200, from its head and body as received.
        private init(status: Int, raw: [UInt8]) {
            let body = raw.firstRange(of: Array("\r\n\r\n".utf8)).map {
                Array(raw[$0.upperBound...])
            }
            let failure = body.flatMap {
                // A body that isn't failure JSON still has its status, which the cases below use.
                try? replyDecoder.decode(TransportFailure.self, from: Data($0))
            }
            switch status {
            case 401: self = .unauthorized
            case 400:
                self = .badRequest(
                    code: failure?.error.code ?? "", message: failure?.error.message ?? "")
            case 500 where failure?.error.code == "internal":
                self = .failed(message: failure?.error.message ?? "")
            default: self = .status(status, code: failure?.error.code)
            }
        }

        package var description: String {
            switch self {
            case .offSubnet: "isn't another device's address on a local subnet"
            case .unreachable(let error): "didn't answer: \(error)"
            case .cancelled: "the request was cancelled"
            case .unauthorized: "refused the token; it must match the service's player_token"
            case .badRequest(let code, let message):
                "refused the request as \(terminalSafe(code)): \(terminalSafe(message))"
            case .failed(let message): "failed: \(terminalSafe(message))"
            case .status(let status, let code):
                "answered with status \(status)" + (code.map { " (\(terminalSafe($0)))" } ?? "")
            case .refused(let refusal): "refused: \(refusal)"
            case .tooLarge(let cap): "sent a reply over the \(cap)-byte cap"
            case .unreadable(let why): "sent a reply that isn't the contract's: \(why)"
            case .unknownState(let state):
                "reports a job in the state \(terminalSafe(state).debugDescription), which this"
                    + " player doesn't know"
            }
        }
    }

    /// The URL the request went to, or the address and port when there was none to make.
    var service: String
    package var kind: Kind

    package var description: String { "music-recommender at \(service) \(kind)" }
}

/// The body of a reply that isn't 200, read only for its code.
private struct TransportFailure: Decodable {
    struct Detail: Decodable {
        var code: String
        var message: String
    }

    var error: Detail
}
