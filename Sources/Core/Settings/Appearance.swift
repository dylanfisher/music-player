/// Light or dark, or following the system.
public enum Appearance: String, SettingChoice {
    case auto, light, dark

    public var title: String {
        switch self {
        case .auto: "Auto"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}
