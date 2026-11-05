/// An item the main window's toolbar can hold. The user picks them and their order in the
/// toolbar's customization sheet; the spaces may appear more than once.
public enum ToolbarItem: String, SettingValue, CaseIterable {
    case transport, volume, status, customStatus1, customStatus2, customStatus3, search, shuffle,
        `repeat`, queue, output, signalPath, flexibleSpace, space

    /// Now-playing bars laid out like the status, each from its own setting (ADR 0089). AppKit
    /// shows a custom item at most once, so each layout is a slot of its own.
    public static let customStatuses: [ToolbarItem] = [
        .customStatus1, .customStatus2, .customStatus3,
    ]

    /// "Custom Status 1" for the slot numbered `number` from 1: the item's label, and the start
    /// of its layout setting's title.
    public static func customStatusTitle(_ number: Int) -> String { "Custom Status \(number)" }

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
