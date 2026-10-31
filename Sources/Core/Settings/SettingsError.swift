/// One key that failed validation, and why.
public struct SettingProblem: Error, Equatable, CustomStringConvertible {
    public enum Reason: Error, Equatable, CustomStringConvertible {
        case unknownKey
        /// `detail` says where inside a structured value the mismatch is.
        case wrongType(expected: String, detail: String?)
        case outOfRange(String)
        case invalid(String)

        public var description: String {
            switch self {
            case .unknownKey: "unknown setting"
            case .wrongType(let expected, let detail):
                "expected \(expected)" + (detail.map { " (\($0))" } ?? "")
            case .outOfRange(let why), .invalid(let why): why
            }
        }
    }

    public var key: String
    public var reason: Reason

    public var description: String { "\"\(key)\": \(reason)" }
}

public enum SettingsError: Error, CustomStringConvertible {
    case unreadable(path: String, reason: String)
    case notJSON(path: String, reason: String)
    case notAnObject(path: String)
    /// Every bad key at once, so one edit fixes them all. `path` is nil for a value set in code.
    case invalid(path: String?, problems: [SettingProblem])

    public var description: String {
        switch self {
        case .unreadable(let path, let reason): "\(path): can't read: \(reason)"
        case .notJSON(let path, let reason): "\(path): isn't valid JSON: \(reason)"
        case .notAnObject(let path): "\(path): must be a JSON object of setting keys and values"
        case .invalid(let path, let problems):
            problems.map { problem in (path.map { "\($0): " } ?? "") + problem.description }
                .joined(separator: "\n")
        }
    }
}
