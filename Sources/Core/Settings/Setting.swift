import Foundation

/// One setting: its key in the JSON file, its default, its title in the settings window and the
/// menus, and the line that explains it. Declare it as a stored property of a `SettingsSchema`.
public struct Setting<Value: SettingValue>: Sendable {
    public let key: String
    /// Title case, as a label or a menu item reads: "Hog Mode".
    public let title: String
    public let defaultValue: Value
    public let summary: String
    public let kind: SettingKind
    private let check: @Sendable (Value) -> SettingProblem.Reason?

    public init(_ key: String, title: String, default defaultValue: Value, _ summary: String) {
        self.init(key, title, defaultValue, summary, Value.kind) { _ in nil }
    }

    private init(
        _ key: String, _ title: String, _ defaultValue: Value, _ summary: String,
        _ kind: SettingKind, check: @escaping @Sendable (Value) -> SettingProblem.Reason?
    ) {
        self.key = key
        self.title = title
        self.defaultValue = defaultValue
        self.summary = summary
        self.kind = kind
        self.check = check
        if let reason = validate(defaultValue) {
            preconditionFailure("the default for \"\(key)\" is invalid: \(reason)")
        }
    }

    /// Why `value` can't be stored, or nil when it can.
    func validate(_ value: Value) -> SettingProblem.Reason? {
        if let problem = value.problem() { return .invalid(problem) }
        return check(value)
    }

    /// Parses a value from `JSONSerialization` output and validates it.
    func decode(json: Any) -> Result<Value, SettingProblem.Reason> {
        let value: Value
        do {
            let data = try JSONSerialization.data(withJSONObject: json, options: .fragmentsAllowed)
            value = try JSONDecoder().decode(Value.self, from: data)
        } catch let error as DecodingError {
            return .failure(.wrongType(expected: Value.typeName, detail: detail(error)))
        } catch {
            return .failure(.wrongType(expected: Value.typeName, detail: "\(error)"))
        }
        return validate(value).map { .failure($0) } ?? .success(value)
    }
}

extension Setting where Value == Int {
    public init(
        _ key: String, title: String, default defaultValue: Int, range: ClosedRange<Int>,
        _ summary: String
    ) {
        self.init(key, title, defaultValue, summary, .integer(range)) { outside(range, $0) }
    }
}

extension Setting where Value == Int? {
    /// An integer in `range`, or null.
    public init(
        _ key: String, title: String, default defaultValue: Int?, range: ClosedRange<Int>,
        _ summary: String
    ) {
        self.init(key, title, defaultValue, summary, .optional(.integer(range))) { value in
            value.flatMap { outside(range, $0) }
        }
    }
}

extension Setting where Value == Double {
    public init(
        _ key: String, title: String, default defaultValue: Double, range: ClosedRange<Double>,
        _ summary: String
    ) {
        self.init(key, title, defaultValue, summary, .number(range)) { outside(range, $0) }
    }
}

private func outside<Bound>(_ range: ClosedRange<Bound>, _ value: Bound) -> SettingProblem.Reason? {
    range.contains(value)
        ? nil : .outOfRange("\(value) is outside \(range.lowerBound)...\(range.upperBound)")
}

/// A setting with its value type erased, so a schema's settings can be listed together.
public struct SettingDescriptor: Sendable {
    public let key: String
    public let title: String
    public let summary: String
    public let kind: SettingKind
    /// Completes "expected …": "true or false".
    public let typeName: String
    public let defaultValue: any SettingValue
    let decode: @Sendable (Any) -> Result<any SettingValue, SettingProblem.Reason>
}

/// Lets `SettingsSchema` find settings among a schema's properties without knowing their types.
protocol DescribedSetting {
    var descriptor: SettingDescriptor { get }
}

extension Setting: DescribedSetting {
    var descriptor: SettingDescriptor {
        SettingDescriptor(
            key: key, title: title, summary: summary, kind: kind, typeName: Value.typeName,
            defaultValue: defaultValue,
            decode: { json in decode(json: json).map { $0 } })
    }
}

/// "[0].kind: Cannot initialize Kind from invalid String value smb", or nil when the mismatch is
/// the whole value, which "expected …" already says.
private func detail(_ error: DecodingError) -> String? {
    switch error {
    case .keyNotFound(let key, let context):
        return codingPath(context.codingPath + [key]) + ": missing"
    case .typeMismatch(_, let context), .valueNotFound(_, let context),
        .dataCorrupted(let context):
        return context.codingPath.isEmpty
            ? nil : codingPath(context.codingPath) + ": " + context.debugDescription
    @unknown default:
        return "\(error)"
    }
}

private func codingPath(_ keys: [any CodingKey]) -> String {
    keys.map { key in key.intValue.map { "[\($0)]" } ?? ".\(key.stringValue)" }.joined()
        .trimmingCharacters(in: CharacterSet(charactersIn: "."))
}
