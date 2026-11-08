import Foundation
import KeyChord

/// One thing wrong with the config file, on a line when it has one.
public struct ConfigProblem: Error, Equatable, CustomStringConvertible {
    public var line: Int?
    public var message: String
    /// The path of keys to a key the app doesn't know, such as an obsolete setting, which is
    /// skipped while the rest of the file applies. Nil for a problem that applies nothing.
    public var obsoleteKey: [String]?
    /// Whether the rest of the file applies anyway, as for a secret withheld from a file other
    /// users can read.
    public var isWarning: Bool

    public init(
        line: Int?, message: String, obsoleteKey: [String]? = nil, isWarning: Bool = false
    ) {
        self.line = line
        self.message = message
        self.obsoleteKey = obsoleteKey
        self.isWarning = isWarning
    }

    /// Whether the file applies nothing while it has this problem.
    public var blocks: Bool { obsoleteKey == nil && !isWarning }

    public var description: String { (line.map { "line \($0): " } ?? "") + message }
}

/// Everything wrong with a config file, for a command-line mode, which reads only a good one.
struct ConfigError: Error, Equatable, CustomStringConvertible {
    var path: String
    var problems: [ConfigProblem]

    var description: String {
        problems.map { "\(path): \($0)" }.joined(separator: "\n")
    }
}

/// Why the config file can't give a shortcut slot, from the registry and the menus' rules, which
/// Settings can't see. Nil when it can.
public typealias ShortcutCheck =
    @Sendable (
        _ id: String, _ position: ShortcutPosition, _ slot: ShortcutSlot
    ) -> String?

/// What a config file that applies sets: the settings it names, the shortcut overrides, and
/// the unknown keys it skipped.
struct ConfigContents: Sendable {
    var values: [String: any SettingValue]
    var shortcuts: ShortcutOverrides
    var skipped: [ConfigProblem] = []
}

/// The config file's format: what it holds, the text of a new one, and the text patches the app
/// writes. docs/decisions/0015-config-file.md.
public enum ConfigFile {
    public static let shortcutsKey = "shortcuts"
    static let shortcutsComment = [
        "The shortcuts you changed, by command ID. \"primary\" and \"alternate\" each take a",
        "shortcut such as \"cmd+shift+k\", or \"\" for none. A slot left out keeps its default.",
    ]

    /// Reads `text`, collecting every problem before throwing. An unknown key, a bad value, a
    /// key set twice and a shortcut `check` refuses are each a problem on their line. Unknown
    /// keys alone don't throw: they're skipped, and listed in `skipped` (ADR 0082).
    /// `conflicts` checks the values in effect against each other, as the schema's does. With
    /// `othersCanRead`, a secret the file sets isn't used, and a warning says why (ADR 0137).
    static func parse(
        _ text: ConfigText, settings: [SettingDescriptor], check: ShortcutCheck,
        conflicts: ([String: any SettingValue]) -> [SettingConflict] = { _ in [] },
        othersCanRead: Bool = false
    ) throws(ConfigErrorList) -> ConfigContents {
        let plain: [UInt8]
        do {
            plain = try text.plainJSON()
        } catch {
            throw ConfigErrorList([error])
        }
        if plain.allSatisfy({ [0x20, 0x09, 0x0A, 0x0D].contains($0) }) {
            throw ConfigErrorList([ConfigProblem(line: nil, message: "the file is empty")])
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: Data(plain))
        } catch {
            let offset = (error as NSError).userInfo["NSJSONSerializationErrorIndex"] as? Int
            throw ConfigErrorList([
                ConfigProblem(line: offset.map(text.line(at:)), message: jsonProblem(error))
            ])
        }
        guard let entries = object as? [String: Any] else {
            throw ConfigErrorList([
                ConfigProblem(line: nil, message: "must be a JSON object of settings")
            ])
        }
        let top: ConfigText.Object
        let duplicates: [(key: String, offset: Int)]
        do {
            (top, duplicates) = try text.scan()
        } catch {
            throw ConfigErrorList([error])
        }
        var problems = duplicates.map {
            ConfigProblem(line: text.line(at: $0.offset), message: "\"\($0.key)\" is set twice")
        }
        func line(_ member: ConfigText.Member?) -> Int? {
            member.map { text.line(at: $0.keyStart) }
        }
        let byKey = Dictionary(uniqueKeysWithValues: settings.map { ($0.key, $0) })
        var values: [String: any SettingValue] = [:]
        var shortcuts: ShortcutOverrides = [:]
        // By key, as `member(_:)` finds them, so a file with thousands of keys isn't searched
        // once per key.
        let members = Dictionary(top.members.map { ($0.key, $0) }) { first, _ in first }
        for (key, json) in entries {
            let member = members[key]
            if key == shortcutsKey {
                shortcuts = parseShortcuts(json, member, text, check, &problems)
                continue
            }
            guard let descriptor = byKey[key] else {
                problems.append(
                    ConfigProblem(
                        line: line(member), message: "unknown setting \"\(key)\"",
                        obsoleteKey: [key]))
                continue
            }
            switch descriptor.decode(json) {
            case .success where othersCanRead && descriptor.isSecret && !(json is NSNull):
                problems.append(
                    ConfigProblem(
                        line: line(member),
                        message: "\"\(key)\" isn't used while other users can read the file;"
                            + " run chmod 600 on it", isWarning: true))
            case .success(let value): values[key] = value
            case .failure(let reason):
                problems.append(ConfigProblem(line: line(member), message: "\"\(key)\": \(reason)"))
            }
        }
        if !problems.contains(where: \.blocks) {
            let effective = Dictionary(
                uniqueKeysWithValues: settings.map { ($0.key, values[$0.key] ?? $0.defaultValue) })
            problems += conflicts(effective).map {
                ConfigProblem(line: line(members[$0.key]), message: "\"\($0.key)\": \($0.reason)")
            }
        }
        problems.sort { ($0.line ?? 0) < ($1.line ?? 0) }
        guard !problems.contains(where: \.blocks) else { throw ConfigErrorList(problems) }
        return ConfigContents(values: values, shortcuts: shortcuts, skipped: problems)
    }

    private static func parseShortcuts(
        _ json: Any, _ member: ConfigText.Member?, _ text: ConfigText, _ check: ShortcutCheck,
        _ problems: inout [ConfigProblem]
    ) -> ShortcutOverrides {
        func line(_ member: ConfigText.Member?) -> Int? {
            member.map { text.line(at: $0.keyStart) }
        }
        guard let commands = json as? [String: Any] else {
            problems.append(
                ConfigProblem(
                    line: line(member), message: "\"shortcuts\" must be an object of command IDs"))
            return [:]
        }
        var overrides: ShortcutOverrides = [:]
        for (id, slots) in commands {
            let command = member?.object?.member(id)
            guard let slots = slots as? [String: Any] else {
                problems.append(
                    ConfigProblem(
                        line: line(command),
                        message:
                            "shortcuts.\(id) must be an object with \"primary\" or \"alternate\""))
                continue
            }
            var override = ShortcutOverride()
            for (name, value) in slots {
                let onLine = line(command?.object?.member(name) ?? command)
                let key = "shortcuts.\(id).\(name)"
                guard let position = ShortcutPosition(rawValue: name) else {
                    problems.append(
                        ConfigProblem(
                            line: onLine,
                            message: "\(key): unknown slot; use \"primary\" or \"alternate\"",
                            obsoleteKey: [shortcutsKey, id, name]))
                    continue
                }
                guard let stored = value as? String else {
                    problems.append(ConfigProblem(line: onLine, message: "\(key) must be a string"))
                    continue
                }
                let slot: ShortcutSlot
                if stored.isEmpty {
                    slot = .removed
                } else if let chord = KeyChord(stored: stored) {
                    slot = .chord(chord)
                } else {
                    problems.append(
                        ConfigProblem(
                            line: onLine,
                            message:
                                "\(key): \"\(stored)\" isn't a shortcut; write it like \"ctrl+opt+cmd+shift+k\""
                        ))
                    continue
                }
                if let problem = check(id, position, slot) {
                    problems.append(ConfigProblem(line: onLine, message: "\(key): \(problem)"))
                    continue
                }
                override[position] = slot
            }
            overrides[id] = override
        }
        return overrides
    }

    /// The text of a new file: every setting at its default, in schema order, each under a
    /// comment of its summary and what it takes, then the empty shortcuts.
    public static func defaultText(settings: [SettingDescriptor]) -> String {
        var entries = settings.map { setting in
            (
                comment: wrap(setting.summary) + ["Takes \(takes(setting))."],
                line: "\(jsonString(setting.key)): \(reindent(jsonText(setting.defaultValue)))"
            )
        }
        entries.append((shortcutsComment, "\(jsonString(shortcutsKey)): {}"))
        let body = entries.map { entry in
            (entry.comment.map { "  // " + $0 } + ["  " + entry.line]).joined(separator: "\n")
        }
        return "{\n" + body.joined(separator: ",\n\n") + "\n}\n"
    }

    /// `text` with `setting` set to `value`: the value's text replaced where the file has the
    /// key, or the key added at the end with its comment. `text` must parse.
    static func patch(_ text: ConfigText, setting: SettingDescriptor, to value: any SettingValue)
        throws -> ConfigText
    {
        var text = text
        let top = try text.scan().object
        let valueText = jsonText(value)
        if let member = top.member(setting.key) {
            text.replaceValue(of: member, with: reindent(valueText, under: text, at: member))
        } else {
            text.insert(
                key: setting.key, value: valueText,
                comment: wrap(setting.summary) + ["Takes \(takes(setting))."], into: top)
        }
        return text
    }

    /// `text` with command `id`'s shortcuts set to `override`; an empty override takes the
    /// command out.
    static func patch(_ text: ConfigText, shortcut id: String, to override: ShortcutOverride)
        throws -> ConfigText
    {
        var text = text
        var top = try text.scan().object
        if top.member(shortcutsKey) == nil {
            guard !override.isEmpty else { return text }
            text.insert(key: shortcutsKey, value: "{}", comment: shortcutsComment, into: top)
            top = try text.scan().object
        }
        guard let shortcuts = top.member(shortcutsKey)?.object else {
            throw ConfigProblem(line: nil, message: "\"shortcuts\" isn't an object")
        }
        let slots = ShortcutPosition.allCases.compactMap { position in
            override[position].map { slot -> String in
                let stored = if case .chord(let chord) = slot { chord.stored } else { "" }
                return "\(jsonString(position.rawValue)): \(jsonString(stored))"
            }
        }
        let value = "{" + slots.joined(separator: ", ") + "}"
        if let member = shortcuts.member(id) {
            if override.isEmpty {
                text.remove(member, from: shortcuts)
            } else {
                text.replaceValue(of: member, with: value)
            }
        } else if !override.isEmpty {
            text.insert(key: id, value: value, comment: [], into: shortcuts)
        }
        return text
    }

    /// `text` without the member at `path`, such as `["appearance.nowPlaying"]` or
    /// `["shortcuts", "play", "third"]`, its line, and the comment lines directly above it, for
    /// Remove Obsolete Setting. The rest of the text stays byte for byte. `text` must parse.
    static func removing(_ path: [String], from text: ConfigText) throws -> ConfigText {
        var text = text
        var object = try text.scan().object
        let missing = ConfigProblem(
            line: nil, message: "\"\(path.joined(separator: "."))\" isn't in the file")
        for key in path.dropLast() {
            guard let inner = object.member(key)?.object else { throw missing }
            object = inner
        }
        guard let last = path.last, let member = object.member(last) else { throw missing }
        text.remove(member, from: object, withComment: true)
        return text
    }

    /// What a setting takes, for its comment: "true or false", "an integer from 1 to 64 or
    /// null".
    static func takes(_ setting: SettingDescriptor) -> String {
        func range(_ kind: SettingKind) -> String {
            switch kind {
            case .integer(let range?): " from \(range.lowerBound) to \(range.upperBound)"
            case .number(let range?): " from \(range.lowerBound) to \(range.upperBound)"
            case .optional(let wrapped): range(wrapped)
            default: ""
            }
        }
        let extra = range(setting.kind)
        guard !extra.isEmpty else { return setting.typeName }
        return setting.typeName.replacingOccurrences(of: " or null", with: "") + extra
            + (setting.typeName.hasSuffix(" or null") ? ", or null" : "")
    }

    /// Lines of at most about 90 characters, for comments.
    private static func wrap(_ text: String) -> [String] {
        var lines: [String] = []
        var line = ""
        for word in text.split(separator: " ") {
            if !line.isEmpty, line.count + word.count + 1 > 90 {
                lines.append(line)
                line = ""
            }
            line += (line.isEmpty ? "" : " ") + word
        }
        return lines + [line]
    }

    private static func reindent(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: "\n  ")
    }

    private static func reindent(
        _ value: String, under text: ConfigText, at member: ConfigText.Member
    )
        -> String
    {
        guard value.contains("\n") else { return value }
        let bytes = text.bytes
        var start = member.keyStart
        while start > 0, bytes[start - 1] != UInt8(ascii: "\n") { start -= 1 }
        let indent = String(
            decoding: bytes[start..<member.keyStart].prefix { $0 == 0x20 || $0 == 0x09 },
            as: UTF8.self)
        return value.replacingOccurrences(of: "\n", with: text.lineEnding + indent)
    }
}

/// The problems a parse found, thrown together.
struct ConfigErrorList: Error {
    var problems: [ConfigProblem]

    init(_ problems: [ConfigProblem]) {
        self.problems = problems
    }
}

/// Why Foundation couldn't parse a file's text as JSON.
func jsonProblem(_ error: any Error) -> String {
    "isn't valid JSON: \((error as NSError).userInfo[NSDebugDescriptionErrorKey] ?? error)"
}

/// A value as the file writes it: pretty-printed, with sorted keys.
func jsonText(_ value: any SettingValue) -> String {
    func encode<Value: SettingValue>(_ value: Value) -> String {
        // A value the schema validated always encodes.
        let data = try! JSONEncoder().encode(value)
        let object = try! JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        let pretty = try! JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        return String(decoding: pretty, as: UTF8.self)
    }
    return encode(value)
}
