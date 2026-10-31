import Foundation
import Settings

/// The General pane's rows, generated from the settings schema, so a new setting appears with
/// no UI code: a control for its kind, its title and its summary. Values go to and from the
/// config file as JSON holds them.
@MainActor
public final class GeneralModel {
    /// The control a row shows for its setting's kind.
    public enum Control: Equatable {
        case checkbox
        case popUp([SettingKind.Choice])
        /// A number field; `whole` takes integers only, `optional` means empty is null.
        case number(whole: Bool, optional: Bool)
        case text(optional: Bool)
        /// Watched folders, which the sidebar adds and removes; listed here.
        case folders
        /// A kind with no control of its own: the value as the config file has it, edited there.
        case readOnly
    }

    public struct Row: Equatable {
        public var key: String
        public var title: String
        public var summary: String
        public var control: Control
    }

    public let rows: [Row]
    private let value: (String) -> Any?
    private let set: (String, Any) throws -> Void

    /// `value` reads a setting as JSON holds it; `set` writes one.
    public init(
        settings: [SettingDescriptor], value: @escaping (String) -> Any?,
        set: @escaping (String, Any) throws -> Void
    ) {
        rows = settings.map(Self.row)
        self.value = value
        self.set = set
    }

    private static func row(_ setting: SettingDescriptor) -> Row {
        let control: Control =
            switch setting.kind {
            case .bool: .checkbox
            case .choice(let choices): .popUp(choices)
            case .integer: .number(whole: true, optional: false)
            case .optional(.integer): .number(whole: true, optional: true)
            case .number: .number(whole: false, optional: false)
            case .optional(.number): .number(whole: false, optional: true)
            case .string: .text(optional: false)
            case .optional(.string): .text(optional: true)
            case .list(.watchedFolder): .folders
            default: .readOnly
            }
        return Row(
            key: setting.key, title: setting.title, summary: setting.summary, control: control)
    }

    public func isOn(_ key: String) -> Bool { value(key) as? Bool == true }

    public func choice(_ key: String) -> String? { value(key) as? String }

    /// A number, text or read-only row's value as it shows it; empty for null.
    public func text(_ key: String) -> String {
        switch value(key) {
        case let number as NSNumber: number.stringValue
        case let string as String: string
        case nil, is NSNull: ""
        case let other?:
            (try? JSONSerialization.data(withJSONObject: other, options: [.sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "\(other)"
        }
    }

    /// The watched folders' paths.
    public func folders(_ key: String) -> [String] {
        (value(key) as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
    }

    public func setOn(_ key: String, _ on: Bool) throws { try set(key, on) }

    public func setChoice(_ key: String, _ raw: String) throws { try set(key, raw) }

    /// Sets a number or text row from what was typed. Empty is null where the setting allows
    /// it; text that isn't a number of the right sort throws, naming the setting.
    public func setText(_ key: String, _ text: String) throws {
        guard let row = rows.first(where: { $0.key == key }) else {
            preconditionFailure("\(key) has no row")
        }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        switch row.control {
        case .number(let whole, let optional):
            if trimmed.isEmpty, optional { return try set(key, NSNull()) }
            let number: Any? = whole ? Int(trimmed) : Double(trimmed)
            guard let number else {
                throw ConfigProblem(
                    line: nil,
                    message: "\(row.title) needs \(whole ? "a whole number" : "a number"),"
                        + " not \"\(text)\"")
            }
            try set(key, number)
        case .text(let optional):
            try set(key, trimmed.isEmpty && optional ? NSNull() : trimmed)
        case .checkbox, .popUp, .folders, .readOnly:
            preconditionFailure("\(key) isn't a text row")
        }
    }
}
