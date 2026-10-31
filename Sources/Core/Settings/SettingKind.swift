/// What a setting holds, in enough detail for the settings window to pick a control.
public indirect enum SettingKind: Sendable, Equatable {
    case bool
    /// With the allowed range, when the setting has one.
    case integer(ClosedRange<Int>?)
    case number(ClosedRange<Double>?)
    case string
    /// One of these raw values.
    case choice([String])
    /// The value or null.
    case optional(SettingKind)
    case list(SettingKind)
    case watchedFolder
}
