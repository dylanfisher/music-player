/// What a setting holds, in enough detail for the settings window to pick a control.
public indirect enum SettingKind: Sendable, Equatable {
    case bool
    /// With the allowed range, when the setting has one.
    case integer(ClosedRange<Int>?)
    case number(ClosedRange<Double>?)
    case string
    /// One of these values.
    case choice([Choice])
    /// The value or null.
    case optional(SettingKind)
    case list(SettingKind)
    case watchedFolder
    case syncFolder
    /// Window layout the app saves as it changes; the settings window shows no control for it.
    case windowState

    public struct Choice: Sendable, Equatable {
        public var rawValue: String
        public var title: String
    }
}
