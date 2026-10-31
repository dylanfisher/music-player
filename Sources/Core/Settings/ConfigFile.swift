import Foundation
import KeyChord

/// One thing wrong with the config file, on a line when it has one.
public struct ConfigProblem: Error, Equatable, CustomStringConvertible {
    public var line: Int?
    public var message: String

    public init(line: Int?, message: String) {
        self.line = line
        self.message = message
    }

    public var description: String { (line.map { "line \($0): " } ?? "") + message }
}

/// Everything wrong with a config file, which is applied only when nothing is.
public struct ConfigError: Error, Equatable, CustomStringConvertible {
    public var path: String
    public var problems: [ConfigProblem]

    public var description: String {
        problems.map { "\(path): \($0)" }.joined(separator: "\n")
    }
}

/// Why the config file can't give a shortcut slot, from the registry and the menus' rules, which
/// Settings can't see. Nil when it can.
public typealias ShortcutCheck =
    @Sendable (
        _ id: String, _ position: ShortcutPosition, _ slot: ShortcutSlot
    ) -> String?

/// What a good config file sets: the settings it names, and the shortcut overrides.
public struct ConfigContents: Sendable {
    public var values: [String: any SettingValue]
    public var shortcuts: ShortcutOverrides
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
    /// key set twice and a shortcut `check` refuses are each a problem on their line.
    static func parse(_ text: ConfigText, settings: [SettingDescriptor], check: ShortcutCheck)
        throws(ConfigErrorList) -> ConfigContents
    {
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
                ConfigProblem(
                    line: offset.map(text.line(at:)),
                    message:
                        "isn't valid JSON: \((error as NSError).userInfo[NSDebugDescriptionErrorKey] ?? error)"
                )
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
        for (key, json) in entries {
            let member = top.member(key)
            if key == shortcutsKey {
                shortcuts = parseShortcuts(json, member, text, check, &problems)
                continue
            }
            guard let descriptor = byKey[key] else {
                problems.append(
                    ConfigProblem(line: line(member), message: "unknown setting \"\(key)\""))
                continue
            }
            switch descriptor.decode(json) {
            case .success(let value): values[key] = value
            case .failure(let reason):
                problems.append(ConfigProblem(line: line(member), message: "\"\(key)\": \(reason)"))
            }
        }
        guard problems.isEmpty else {
            throw ConfigErrorList(problems.sorted { ($0.line ?? 0) < ($1.line ?? 0) })
        }
        return ConfigContents(values: values, shortcuts: shortcuts)
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
                            message: "\(key): unknown slot; use \"primary\" or \"alternate\""))
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
