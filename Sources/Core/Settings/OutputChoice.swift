/// An output the user can pick: the system's default device, a Core Audio device by UID, or a
/// UPnP renderer by UDN. `output.deviceUID` and `output.renderer` hold it (ADR 0044).
public enum OutputChoice: Hashable, Sendable {
    case systemDefault
    case device(uid: String)
    case renderer(udn: String)

    /// What the config's two settings name: the renderer when one is set, since it plays
    /// instead of the device, then the device.
    public init(deviceUID: String?, renderer: String?) {
        if let renderer {
            self = .renderer(udn: renderer)
        } else if let deviceUID {
            self = .device(uid: deviceUID)
        } else {
            self = .systemDefault
        }
    }

    /// `output.deviceUID` and `output.renderer` once this is picked, from `deviceUID` as it is
    /// now. A device clears the renderer. A renderer keeps the device, which plays again when the
    /// renderer is cleared and must not switch underneath the track still playing on it.
    public func settings(deviceUID: String?) -> (deviceUID: String?, renderer: String?) {
        switch self {
        case .systemDefault: (nil, nil)
        case .device(let uid): (uid, nil)
        case .renderer(let udn): (deviceUID, udn)
        }
    }

    /// The choice as text, for a palette row's key: `output:`, `output:device:<uid>` or
    /// `output:renderer:<udn>`.
    public var text: String {
        switch self {
        case .systemDefault: Self.prefix
        case .device(let uid): Self.prefix + Self.device + uid
        case .renderer(let udn): Self.prefix + Self.renderer + udn
        }
    }

    public init?(text: String) {
        guard text.hasPrefix(Self.prefix) else { return nil }
        let rest = text.dropFirst(Self.prefix.count)
        if rest.isEmpty {
            self = .systemDefault
        } else if rest.hasPrefix(Self.device), rest.count > Self.device.count {
            self = .device(uid: String(rest.dropFirst(Self.device.count)))
        } else if rest.hasPrefix(Self.renderer), rest.count > Self.renderer.count {
            self = .renderer(udn: String(rest.dropFirst(Self.renderer.count)))
        } else {
            return nil
        }
    }

    private static let prefix = "output:"
    private static let device = "device:"
    private static let renderer = "renderer:"
}

/// A device or renderer that was found, by its UID or UDN and the name it gives.
public struct FoundOutput: Equatable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// One entry of the output picker.
public struct OutputOption: Equatable, Sendable {
    public var choice: OutputChoice
    public var title: String
}

/// The outputs to pick from, as the Output menu, the palette and the Settings window list them:
/// System Default, each device, then each renderer, by name. The one `current` names stays listed
/// by its UID or UDN while it isn't found, so a setting isn't lost from view.
public func outputOptions(
    devices: [FoundOutput], renderers: [FoundOutput], current: OutputChoice
) -> [OutputOption] {
    var devices = devices.map { OutputOption(choice: .device(uid: $0.id), title: $0.name) }
    var renderers = renderers.map { OutputOption(choice: .renderer(udn: $0.id), title: $0.name) }
    switch current {
    case .device(let uid) where !devices.contains { $0.choice == current }:
        devices.append(OutputOption(choice: current, title: "\(uid) (not connected)"))
    case .renderer(let udn) where !renderers.contains { $0.choice == current }:
        renderers.append(OutputOption(choice: current, title: "\(udn) (not found)"))
    default: break
    }
    return [OutputOption(choice: .systemDefault, title: systemDefaultOutputTitle)] + devices
        + renderers
}

/// The picker's first entry, which `output.deviceUID` null plays through.
let systemDefaultOutputTitle = "System Default"
