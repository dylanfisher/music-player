import Settings

/// A command made from a setting: a toggle for each Boolean, and one command for each value of
/// a choice, so a new setting of either kind is in the menus, the palette and the Shortcuts pane
/// with no code of its own. Other settings aren't commands; the palette lists them and opens
/// the Settings window at their row.
public struct SettingCommand: Sendable {
    public enum Action: Equatable, Sendable {
        case toggle
        /// Sets the choice to this raw value.
        case choose(String)
    }

    public let key: String
    public let action: Action
    public let command: Command

    /// Every setting command `schema` gives, in declaration order.
    public static func all(_ schema: some SettingsSchema) -> [SettingCommand] {
        schema.settings.flatMap { setting -> [SettingCommand] in
            switch setting.kind {
            case .bool:
                return [
                    SettingCommand(
                        key: setting.key, action: .toggle,
                        command: Command(toggleID(setting.key), setting.title))
                ]
            case .choice(let choices):
                return choices.map { choice in
                    SettingCommand(
                        key: setting.key, action: .choose(choice.rawValue),
                        command: Command(
                            chooseID(setting.key, choice.rawValue),
                            "\(choice.title) \(setting.title)"))
                }
            default:
                return []
            }
        }
    }

    static func toggleID(_ key: String) -> CommandID { CommandID("setting.\(key)") }

    static func chooseID(_ key: String, _ value: String) -> CommandID {
        CommandID("setting.\(key).\(value)")
    }

    /// What the palette calls a toggle: what running it would do, "Turn Off Hog Mode".
    public static func paletteTitle(_ title: String, isOn: Bool) -> String {
        (isOn ? "Turn Off " : "Turn On ") + title
    }
}
