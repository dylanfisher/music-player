import DisplayText
import Settings

/// The `error` of a 200 with `ok: false`: a request the service understood and refused. Clients
/// branch on `code`; `message` is for a person. The other fields come with the codes the
/// contract lists them for.
package struct ServiceRefusal: Equatable, Sendable, Decodable, CustomStringConvertible {
    enum Code: String, Equatable, Sendable, Decodable {
        /// The service's config has no downloads tables.
        case downloadsOff = "downloads_off"
        /// A job for the release that isn't terminal exists: `jobID`.
        case alreadyActive = "already_active"
        case noSuchJob = "no_such_job"
        /// The job's `state` doesn't allow the request.
        case illegalTransition = "illegal_transition"
        /// Another `machine` holds the claim or lease until `expiresAt`.
        case claimed
        /// No one holds the claim or lease the event needs; this machine takes it first.
        case notClaimed = "not_claimed"
    }

    var code: Code
    var message: String
    var jobID: Int? = nil
    /// For `illegalTransition`, the job's state.
    package var state: String? = nil
    var machine: String? = nil
    var expiresAt: Int? = nil

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case code, message
        case jobID = "job_id"
        case state, machine
        case expiresAt = "expires_at"
    }

    init(code: Code, message: String) {
        self.code = code
        self.message = message
    }

    package init(from decoder: any Decoder) throws {
        let container = try strictContainer(decoder, CodingKeys.self)
        code = try container.decode(Code.self, forKey: .code)
        message = try container.decode(String.self, forKey: .message)
        jobID = try container.decodeIfPresent(Int.self, forKey: .jobID)
        state = try container.decodeIfPresent(String.self, forKey: .state)
        machine = try container.decodeIfPresent(String.self, forKey: .machine)
        expiresAt = try container.decodeIfPresent(Int.self, forKey: .expiresAt)
    }

    package var description: String { "\(code.rawValue): \(terminalSafe(message))" }
}
