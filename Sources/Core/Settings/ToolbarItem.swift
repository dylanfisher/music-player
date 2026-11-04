/// An item the main window's toolbar can hold. The user picks them and their order in the
/// toolbar's customization sheet; the spaces may appear more than once.
public enum ToolbarItem: String, SettingValue, CaseIterable {
    case transport, volume, status, search, shuffle, `repeat`, queue, output, signalPath,
        flexibleSpace, space

    /// Swinsian's: the transport, the volume, the now-playing status, shuffle and search, with
    /// flexible space between them.
    public static let defaultItems: [ToolbarItem] = [
        .transport, .flexibleSpace, .volume, .flexibleSpace, .status, .flexibleSpace, .shuffle,
        .flexibleSpace, .search,
    ]

    public static var typeName: String {
        "a toolbar item (" + allCases.map(\.rawValue).joined(separator: ", ") + ")"
    }
    public static var kind: SettingKind { .windowState }
}
