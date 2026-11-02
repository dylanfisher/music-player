/// An item the main window's toolbar can hold. The user picks them and their order in the
/// toolbar's customization sheet; the spaces may appear more than once.
public enum ToolbarItem: String, SettingValue, CaseIterable {
    case transport, volume, status, search, shuffle, `repeat`, queue, output, signalPath,
        flexibleSpace, space

    /// The header as it was before it could be customized: the transport, the now-playing
    /// status, the queue button and search.
    public static let defaultItems: [ToolbarItem] = [.transport, .status, .queue, .search]

    public static var typeName: String {
        "a toolbar item (" + allCases.map(\.rawValue).joined(separator: ", ") + ")"
    }
    public static var kind: SettingKind { .windowState }
}
