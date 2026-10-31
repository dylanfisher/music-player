import Foundation

/// A type a setting can hold. It goes to and from JSON through Codable, and describes itself for
/// error messages and the settings window.
public protocol SettingValue: Codable, Equatable, Sendable {
    /// Completes "expected …" in an error.
    static var typeName: String { get }
    static var kind: SettingKind { get }
    /// Why a value of the right type is still invalid, or nil when it's fine.
    func problem() -> String?
}

extension SettingValue {
    public func problem() -> String? { nil }

    func isEqual(to other: any SettingValue) -> Bool { (other as? Self) == self }
}

/// A setting with a fixed set of values, stored as their raw strings.
public protocol SettingChoice: SettingValue, CaseIterable, RawRepresentable<String> {
    /// Title case, as a menu item or a pop-up button shows it: "Dark".
    var title: String { get }
}

extension SettingChoice {
    public static var typeName: String {
        "one of " + allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
    }
    public static var kind: SettingKind {
        .choice(allCases.map { SettingKind.Choice(rawValue: $0.rawValue, title: $0.title) })
    }
}

extension Bool: SettingValue {
    public static var typeName: String { "true or false" }
    public static var kind: SettingKind { .bool }
}

extension Int: SettingValue {
    public static var typeName: String { "an integer" }
    public static var kind: SettingKind { .integer(nil) }
}

extension Double: SettingValue {
    public static var typeName: String { "a number" }
    public static var kind: SettingKind { .number(nil) }
}

extension String: SettingValue {
    public static var typeName: String { "a string" }
    public static var kind: SettingKind { .string }
}

extension Optional: SettingValue where Wrapped: SettingValue {
    public static var typeName: String { "\(Wrapped.typeName) or null" }
    public static var kind: SettingKind { .optional(Wrapped.kind) }
    public func problem() -> String? { self?.problem() }
}

extension Array: SettingValue where Element: SettingValue {
    public static var typeName: String { "a list of \(Element.typeName)" }
    public static var kind: SettingKind { .list(Element.kind) }
    public func problem() -> String? {
        for (index, element) in enumerated() {
            if let problem = element.problem() { return "item \(index): \(problem)" }
        }
        return nil
    }
}
