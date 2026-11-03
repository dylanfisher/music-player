import Foundation
import Settings

/// The Settings window's rows, generated from the settings schema, so a new setting appears with
/// no UI code: a control for its kind, its title and its summary, in a section by its key.
/// Values go to and from the config file as JSON holds them.
@MainActor
public final class GeneralModel {
    /// The control a row shows for its setting's kind.
    enum Control: Equatable {
        case checkbox
        case popUp([SettingKind.Choice])
        /// A number field; `whole` takes integers only, `optional` means empty is null.
        case number(whole: Bool, optional: Bool)
        case text(optional: Bool)
        /// Watched folders, which the Watched Folders pane lists, adds and removes.
        case folders
        /// The sync folder, with buttons to choose one and to clear it.
        case syncFolder
        /// The output device, picked from the devices and renderers found.
        case output
        /// The network renderer, which the output device's row lists and picks too.
        case renderer
        /// A list of choices in an order: each choice with a checkbox, dragged to reorder.
        case checklist([SettingKind.Choice])
        /// A kind with no control of its own: the value as the config file has it, edited there.
        case readOnly
    }

    public struct Row: Equatable {
        public var key: String
        public var title: String
        public var summary: String
        var control: Control
        /// What a number field's value is in, shown after the field.
        var unit: String? = nil
    }

    /// The panes' groups of rows, each in a titled box, by what the setting's key starts with.
    enum Section: CaseIterable {
        /// The Playback pane's.
        case output, playCounts
        case library, sync, receiver
        /// Shown under the Watched Folders pane's list, as Swinsian has them.
        case networkFolders
        case appearance
        /// A key no section claims; a test keeps the app's settings out of it.
        case other

        var title: String {
            switch self {
            case .output: "Audio Output"
            case .playCounts: "Play Counts"
            case .library: "Library"
            case .sync: "Sync"
            case .receiver: "Receiver"
            case .networkFolders: "Network Folders"
            case .appearance: AppSettings().appearance.title
            case .other: "Other"
            }
        }

        /// The key prefixes of the section's settings; the longest that matches a key wins.
        var prefixes: [String] {
            let schema = AppSettings()
            return switch self {
            case .output: ["output."]
            case .playCounts: ["playback."]
            case .library: ["library."]
            case .sync: ["sync."]
            case .receiver: ["receiver."]
            case .networkFolders:
                [schema.pausePollingDuringPlayback.key, schema.rescanNetworkFoldersAtLaunch.key]
            case .appearance: [schema.appearance.key]
            case .other: []
            }
        }

        /// The checkbox that turns the section's other settings on; they're disabled while it's
        /// off, so the box reads as what depends on what.
        var switchKey: String? {
            switch self {
            case .receiver: AppSettings().receiverEnabled.key
            default: nil
            }
        }

        init(key: String) {
            let matches = Self.allCases.flatMap { section in
                section.prefixes.filter { key.hasPrefix($0) }.map { (section, $0.count) }
            }
            self = matches.max { $0.1 < $1.1 }?.0 ?? .other
        }
    }

    /// A row for each setting the window shows; the rest are edited in the config file.
    public let rows: [Row]
    /// The sections in order, each with its rows in schema order; the watched
    /// folders have a pane of their own.
    var sections: [(section: Section, rows: [Row])] {
        Section.allCases.compactMap { section in
            let shown = rows.filter {
                ![.folders, .renderer].contains($0.control) && Section(key: $0.key) == section
            }
            return shown.isEmpty ? nil : (section, shown)
        }
    }
    /// The watched folders' row, which the Watched Folders pane shows.
    var foldersRow: Row? { rows.first { $0.control == .folders } }
    private let value: (String) -> Any?
    private let set: (String, Any) throws -> Void

    /// `value` reads a setting as JSON holds it; `set` writes one. `searcherInstalled` says
    /// whether the File Viewer setting has a choice to make.
    public init(
        settings: [SettingDescriptor], searcherInstalled: Bool, value: @escaping (String) -> Any?,
        set: @escaping (String, Any) throws -> Void
    ) {
        rows = settings.filter { Self.isShown($0.key, searcherInstalled: searcherInstalled) }
            .map(Self.row)
        self.value = value
        self.set = set
    }

    /// Whether the window has a row for the setting. Network Scan Readers is a tuning number
    /// few would understand, and File Viewer has nothing to pick without Searcher, so both stay
    /// in the config file (ADR 0067).
    private static func isShown(_ key: String, searcherInstalled: Bool) -> Bool {
        let schema = AppSettings()
        return switch key {
        case schema.networkScanReaders.key: false
        case schema.fileViewer.key: searcherInstalled
        default: true
        }
    }

    private static func row(_ setting: SettingDescriptor) -> Row {
        let schema = AppSettings()
        let control: Control =
            switch setting.kind {
            case _ where setting.key == schema.outputDeviceUID.key: .output
            case _ where setting.key == schema.outputRenderer.key: .renderer
            case .bool: .checkbox
            case .choice(let choices): .popUp(choices)
            case .integer: .number(whole: true, optional: false)
            case .optional(.integer): .number(whole: true, optional: true)
            case .number: .number(whole: false, optional: false)
            case .optional(.number): .number(whole: false, optional: true)
            case .string: .text(optional: false)
            case .optional(.string): .text(optional: true)
            case .list(.watchedFolder): .folders
            case .optional(.syncFolder): .syncFolder
            case .list(.choice(let choices)): .checklist(choices)
            default: .readOnly
            }
        return Row(
            key: setting.key, title: setting.title, summary: setting.summary, control: control,
            unit: setting.key == schema.playedPercent.key ? "%" : nil)
    }

    /// Whether a row can be changed now: not while its section's switch is off.
    func isEnabled(_ key: String) -> Bool {
        guard let switchKey = Section(key: key).switchKey, switchKey != key else { return true }
        return isOn(switchKey)
    }

    public func isOn(_ key: String) -> Bool { value(key) as? Bool == true }

    public func choice(_ key: String) -> String? { value(key) as? String }

    /// The output the config names, as the output device's row shows it picked.
    var output: OutputChoice {
        let schema = AppSettings()
        return OutputChoice(
            deviceUID: choice(schema.outputDeviceUID.key),
            renderer: choice(schema.outputRenderer.key))
    }

    /// A number, text or read-only row's value as it shows it; empty for null.
    public func text(_ key: String) -> String {
        switch value(key) {
        case let number as NSNumber: number.stringValue
        case let string as String: string
        case nil, is NSNull: ""
        case let other?:
            (try? JSONSerialization.data(withJSONObject: other, options: [.sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "\(other)"
        }
    }

    /// A watched folder as the Watched Folders pane lists it.
    struct Folder: Equatable {
        /// The path, and for a folder on a share, the share it's in (ADR 0028).
        var location: String
        var kind: String
        /// How often it's rescanned.
        var rescans: String
        /// For a network folder, how often it's rescanned on a timer, which the Rescans column
        /// edits; nil for a local folder, which FSEvents watches and is never polled.
        var interval: Rescans? = nil
    }

    /// How often a network folder is rescanned on a timer: `pollIntervalMinutes`, or null for
    /// never (ADR 0082).
    enum Rescans: Hashable {
        case every(minutes: Int)
        case never
    }

    /// The intervals the Rescans column offers, inside the range the schema allows.
    static let rescanIntervalsMinutes = [1, 5, 15, 30, 60, 120, 360, 720, 1440].filter {
        WatchedFolder.pollIntervalRangeMinutes.contains($0)
    }

    /// The Rescans column's text for a network folder.
    static func rescansText(_ rescans: Rescans) -> String {
        switch rescans {
        case .never: "Never"
        case .every(minutes: 60): "Every hour"
        case .every(let minutes) where minutes > 60 && minutes.isMultiple(of: 60):
            "Every \(minutes / 60) hours"
        case .every(let minutes): "Every \(minutes) min"
        }
    }

    /// What a folder's popup lists: the offered intervals, plus the folder's own when the config
    /// file sets one that isn't offered, so the popup shows what is in effect, then Never.
    static func rescanChoices(_ folder: Folder) -> [Rescans] {
        var minutes = rescanIntervalsMinutes
        if case .every(let own) = folder.interval, !minutes.contains(own) {
            minutes = (minutes + [own]).sorted()
        }
        return minutes.map { .every(minutes: $0) } + [.never]
    }

    /// The watched folders, in the setting's order.
    func folders(_ key: String) -> [Folder] {
        (value(key) as? [[String: Any]] ?? []).compactMap { folder in
            guard let location = folderText(folder) else { return nil }
            guard folder["kind"] as? String == WatchedFolder.Kind.network.rawValue else {
                return Folder(location: location, kind: "Local", rescans: "On change")
            }
            let interval: Rescans? =
                switch folder[WatchedFolder.pollIntervalMinutesKey] {
                case let minutes as Int: .every(minutes: minutes)
                case is NSNull: .never
                default: nil
                }
            return Folder(
                location: location, kind: "Network",
                rescans: interval.map(Self.rescansText) ?? noValueText, interval: interval)
        }
    }

    /// Sets how often the network folder at `position` in the setting is rescanned, keeping the
    /// rest of the folder as the config file has it.
    func setPollInterval(_ key: String, at position: Int, to rescans: Rescans) throws {
        var folders = value(key) as? [[String: Any]] ?? []
        guard folders.indices.contains(position) else {
            throw ConfigProblem(
                line: nil, message: "\(key) has no folder \(position + 1) to set the rescans of")
        }
        folders[position][WatchedFolder.pollIntervalMinutesKey] =
            switch rescans {
            case .every(let minutes): minutes
            case .never: NSNull()
            }
        try set(key, folders)
    }

    /// The sync folder as `folders` shows a folder; nil for none.
    public func syncFolder(_ key: String) -> String? {
        (value(key) as? [String: Any]).flatMap(folderText)
    }

    /// The sync folder's own name, or its share's for the share itself; nil for none.
    func syncFolderName(_ key: String) -> String? {
        guard let folder = value(key) as? [String: Any], let path = folder["path"] as? String
        else { return nil }
        guard path.isEmpty, let share = folder["share"] as? String else {
            return (path as NSString).lastPathComponent
        }
        return URL(string: share)?.lastPathComponent ?? share
    }

    /// A checklist's row: a choice and whether the list holds it.
    struct ChecklistItem: Equatable {
        var choice: SettingKind.Choice
        var isOn: Bool
    }

    /// Every choice of a checklist: those the list holds, in its order, then the rest in the
    /// schema's order.
    func checklist(_ key: String) -> [ChecklistItem] {
        guard let row = rows.first(where: { $0.key == key }),
            case .checklist(let choices) = row.control
        else { preconditionFailure("\(key) isn't a checklist") }
        let held = value(key) as? [String] ?? []
        let on = held.compactMap { raw in choices.first { $0.rawValue == raw } }
        return on.map { ChecklistItem(choice: $0, isOn: true) }
            + choices.filter { !held.contains($0.rawValue) }.map {
                ChecklistItem(choice: $0, isOn: false)
            }
    }

    /// Saves the choices that are on, in `items`' order.
    func setChecklist(_ key: String, _ items: [ChecklistItem]) throws {
        try set(key, items.filter(\.isOn).map(\.choice.rawValue))
    }

    func clear(_ key: String) throws { try set(key, NSNull()) }

    func setOn(_ key: String, _ on: Bool) throws { try set(key, on) }

    func setChoice(_ key: String, _ raw: String) throws { try set(key, raw) }

    /// Sets a number or text row from what was typed. Empty is null where the setting allows
    /// it; text that isn't a number of the right sort throws, naming the setting.
    func setText(_ key: String, _ text: String) throws {
        guard let row = rows.first(where: { $0.key == key }) else {
            preconditionFailure("\(key) has no row")
        }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        switch row.control {
        case .number(let whole, let optional):
            if trimmed.isEmpty, optional { return try set(key, NSNull()) }
            let number: Any? = whole ? Int(trimmed) : Double(trimmed)
            guard let number else {
                throw ConfigProblem(
                    line: nil,
                    message: "\(row.title) needs \(whole ? "a whole number" : Double.typeName),"
                        + " not \"\(text)\"")
            }
            try set(key, number)
        case .text(let optional):
            try set(key, trimmed.isEmpty && optional ? NSNull() : trimmed)
        case .checkbox, .popUp, .folders, .syncFolder, .output, .renderer, .checklist, .readOnly:
            preconditionFailure("\(key) isn't a text row")
        }
    }
}

/// A folder as the config file holds it, by path or by share and the path inside it.
private func folderText(_ folder: [String: Any]) -> String? {
    guard let path = folder["path"] as? String else { return nil }
    guard let share = folder["share"] as? String else { return path }
    return path.isEmpty ? share : "\(path) on \(share)"
}
