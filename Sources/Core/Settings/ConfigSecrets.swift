import Foundation

/// The config file's text with its secrets taken out, for a snapshot's copy of it, and with
/// the live file's secrets put back, for a restore of that copy (ADR 0181). The secrets are the
/// settings whose kind is secret: the Discogs token and the service token.
public enum ConfigSecrets {
    /// The keys of the settings that hold a secret.
    static let keys = AppSettings().settings.filter(\.isSecret).map(\.key).sorted()

    /// `text` as plain JSON without any member a secret's key names, however often it's set.
    /// Comments go too, since a token commented out is still a token, and so do trailing
    /// commas, the byte order mark, the lines they leave blank and spaces at line ends; every
    /// other member stays as written. Throws when `text` isn't a JSON object, as then a secret
    /// can't be told from the rest.
    public static func removed(from text: String) throws(ConfigProblem) -> String {
        var plain = ConfigText(bytes: try objectJSON(text))
        while true {
            let top = try plain.scan().object
            guard let secret = top.members.first(where: { keys.contains($0.key) }) else { break }
            plain.remove(secret, from: top)
        }
        // A line break can't be inside a JSON string, so each line's ends are outside one.
        let lines = plain.string.components(separatedBy: "\n")
            .map { line in String(line.reversed().drop(while: \.isWhitespace).reversed()) }
            .filter { !$0.isEmpty }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `restored`, a snapshot's copy, with each secret `live` sets, the config file's text
    /// now, at the value it has there, and no other: a restore never loses or changes a token.
    /// A `live` of nil, no file, sets none. Throws when either isn't a JSON object.
    public static func kept(from live: String?, in restored: String) throws(ConfigProblem)
        -> String
    {
        var text = ConfigText(try removed(from: restored))
        guard let live else { return text.string }
        let current = ConfigText(bytes: try objectJSON(live))
        let top = try current.scan().object
        for key in keys {
            guard let member = top.member(key) else { continue }
            let value = String(
                decoding: current.bytes[member.valueStart..<member.valueEnd], as: UTF8.self)
            text.insert(key: key, value: value, comment: [], into: try text.scan().object)
        }
        return text.string
    }

    /// `text` with its comments, trailing commas and byte order mark blanked, once Foundation
    /// has read it as a JSON object.
    private static func objectJSON(_ text: String) throws(ConfigProblem) -> [UInt8] {
        let plain = try ConfigText(text).plainJSON()
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: Data(plain))
        } catch {
            throw ConfigProblem(line: nil, message: jsonProblem(error))
        }
        guard object is [String: Any] else {
            throw ConfigFile.notAnObject
        }
        return plain
    }
}
