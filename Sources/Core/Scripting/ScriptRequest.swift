import Commands
import Settings

/// What the tool asks the app, as JSON on the socket.
public enum ScriptRequest: Equatable, Sendable {
    /// A registry command, with the argument it declares, if any.
    case run(CommandID, argument: String?)
    case status

    /// Why `text` can't be an argument: too long, or holding a control character, which no
    /// search or name needs and a link could use to forge text.
    static func argumentProblem(_ text: String) -> String? {
        if text.utf8.count > ScriptLimits.argumentBytes {
            return "the argument is over \(ScriptLimits.argumentBytes) bytes"
        }
        if text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
            return "the argument holds a control character"
        }
        return nil
    }
}

extension ScriptRequest: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind, command, argument
    }

    private enum Kind: String, Codable {
        case run, status
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(decoder, CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .run:
            try onlyKeys(container, [.kind, .command, .argument])
            self = .run(
                CommandID(try container.decode(String.self, forKey: .command)),
                argument: try container.decodeIfPresent(String.self, forKey: .argument))
        case .status:
            try onlyKeys(container, [.kind])
            self = .status
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .run(let id, let argument):
            try container.encode(Kind.run, forKey: .kind)
            try container.encode(id.rawValue, forKey: .command)
            try container.encodeIfPresent(argument, forKey: .argument)
        case .status:
            try container.encode(Kind.status, forKey: .kind)
        }
    }
}
