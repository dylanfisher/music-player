/// A type whose stored properties are `Setting`s. Adding a property is all it takes to add a
/// setting: the store, export and import, and the settings window find it through `settings`.
public protocol SettingsSchema: Sendable {}

extension SettingsSchema {
    /// Every setting, in declaration order.
    public var settings: [SettingDescriptor] {
        Mirror(reflecting: self).children.compactMap {
            ($0.value as? any DescribedSetting)?.descriptor
        }
    }
}
