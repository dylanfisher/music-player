import Commands
import Settings

/// What the tool asks the app, as JSON on the socket.
public enum ScriptRequest: Equatable, Sendable {
    /// A registry command, with the argument it declares, if any.
    case run(CommandID, argument: String?)
    /// A registry command that answers with what it found (`Command.replies`), as text or as
    /// JSON, with the absolute paths it's given if it takes them.
    case report(CommandID, argument: String?, json: Bool, paths: [String] = [])
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

    /// Why `path` can't be one of a command's paths: as for an argument, or not absolute.
    static func pathProblem(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return "\(path) isn't an absolute path" }
        return argumentProblem(path).map { "a path: " + $0 }
    }
}

extension ScriptRequest: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind, command, argument, json, paths
    }

    private enum Kind: String, Codable {
        case run, report, status
    }

    public init(from decoder: any Decoder) throws {
        let container = try strictContainer(decoder, CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .run:
            try onlyKeys(container, [.kind, .command, .argument])
            self = .run(
                CommandID(try container.decode(String.self, forKey: .command)),
                argument: try container.decodeIfPresent(String.self, forKey: .argument))
        case .report:
            try onlyKeys(container, [.kind, .command, .argument, .json, .paths])
            self = .report(
                CommandID(try container.decode(String.self, forKey: .command)),
                argument: try container.decodeIfPresent(String.self, forKey: .argument),
                json: try container.decode(Bool.self, forKey: .json),
                paths: try container.decodeIfPresent([String].self, forKey: .paths) ?? [])
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
        case .report(let id, let argument, let json, let paths):
            try container.encode(Kind.report, forKey: .kind)
            try container.encode(id.rawValue, forKey: .command)
            try container.encodeIfPresent(argument, forKey: .argument)
            try container.encode(json, forKey: .json)
            if !paths.isEmpty { try container.encode(paths, forKey: .paths) }
        case .status:
            try container.encode(Kind.status, forKey: .kind)
        }
    }
}
