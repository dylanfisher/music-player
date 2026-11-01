/// A type whose stored properties are `Setting`s. Adding a property is all it takes to add a
/// setting: the store, export and import, and the settings window find it through `settings`.
public protocol SettingsSchema: Sendable {
    /// What's wrong between settings, given every setting's value in effect by key: a value
    /// each is fine alone that can't go with another's.
    func conflicts(_ values: [String: any SettingValue]) -> [SettingConflict]
}

extension SettingsSchema {
    /// Every setting, in declaration order.
    public var settings: [SettingDescriptor] {
        Mirror(reflecting: self).children.compactMap {
            ($0.value as? any DescribedSetting)?.descriptor
        }
    }

    public func conflicts(_ values: [String: any SettingValue]) -> [SettingConflict] { [] }
}

/// A setting whose value can't go with another setting's, and why.
public struct SettingConflict: Equatable, Sendable {
    public var key: String
    public var reason: String
}
