import Foundation
import Settings

/// The schema, built once: building it checks every setting's default, and the model reads its
/// keys for each setting and each row.
private let schema = AppSettings()

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
        /// A text field for a template, beside a help button that lists its tokens, and Reset
        /// to Default.
        case template([SettingKind.Token])
        /// Watched folders, which the Watched Folders pane lists, adds and removes.
        case folders
        /// The sync folder, with buttons to choose one and to clear it.
        case syncFolder
        /// The staging folder, with buttons to choose one and to clear it.
        case stagingFolder
        /// A folder's path, with buttons to choose one and to clear it: `emptyText` shows while
        /// it's null, and the panel that asks for one says `message`.
        case folder(emptyText: String, message: String)
        /// The output device, picked from the devices and renderers found.
        case output
        /// The network renderer, which the output device's row lists and picks too.
        case renderer
        /// Columns of parts, which a button opens the bar builder on, and the setting's default.
        case barLayout(SettingKind.Bar, defaultLayout: BarLayout<String>)
        /// A color well, with a button that sets null when the setting allows it.
        case color(optional: Bool)
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
        /// For a fallback few need: the line whose disclosure triangle shows the row, which
        /// stays hidden under it until opened or given a value.
        var disclosure: String? = nil
        /// The line the row shares with the rows of the same group, which the pane shows under
        /// the group's title and summary, each row a button of its own.
        var group: RowGroup? = nil
        /// For an IP address: the field's placeholder, the form an address takes, and a Save
        /// button beside it, since Return or leaving the field isn't an obvious way to save.
        var address: String? = nil
    }

    /// An IP address row's placeholder: an address alone, since the port has its own row and
    /// a scheme or a host name is refused.
    static let addressPlaceholder = "192.168.1.10"

    /// Rows of one kind shown on one line, under one label and summary, as the Custom Status
    /// layouts are: each row is a button titled with its number, counted from 1.
    struct RowGroup: Equatable {
        var title: String
        var summary: String
        var number: Int

        var buttonTitle: String { "Edit \(number)…" }

        /// The Custom Status layouts' group, for the setting at `position` among them.
        static func customStatus(_ position: Int) -> RowGroup {
            RowGroup(
                title: "Custom Status Layouts", summary: "What each Custom Status item shows.",
                number: position + 1)
        }
    }

    /// The panes' groups of rows, each in a titled box, by what the setting's key starts with.
    enum Section: CaseIterable {
        /// The Playback pane's.
        case output, playCounts
        case sync, receiver, downloads
        /// The Watched Folders pane's, under its list, as Swinsian has them.
        case folderChanges, networkFolders
        /// The Library pane's.
        case libraryFolder, browsing, database
        /// The Appearance pane's.
        case theme, trackTable
        /// The Toolbar pane's, in the window's order from its top.
        case titles, toolbarStatus, statusBar
        /// A key no section claims; a test keeps the app's settings out of it.
        case other

        var title: String {
            switch self {
            case .output: "Audio Output"
            case .playCounts: "Play Counts"
            case .browsing: "Browsing"
            case .database: "Database"
            case .sync: "Sync"
            case .receiver: "Receiver"
            case .downloads: "Downloads"
            case .folderChanges: "Folder Changes"
            case .libraryFolder: schema.libraryFolder.title
            case .networkFolders: "Network Folders"
            case .theme: "Theme"
            case .trackTable: AppState().trackTable.title
            case .titles: "Titles"
            case .toolbarStatus: "Toolbar Status"
            case .statusBar: schema.statusBarStyle.title
            case .other: "Other"
            }
        }

        /// The key prefixes of the section's settings; the longest that matches a key wins.
        var prefixes: [String] {
            return switch self {
            case .output: ["output."]
            case .playCounts: ["playback."]
            // `library.` is every library key's prefix, so a new one shows here until it's
            // given a section.
            case .browsing: ["library."]
            case .database: [schema.snapshotFolder.key]
            case .sync: ["sync."]
            case .receiver: ["receiver."]
            case .downloads: ["recommender.", "import."]
            case .folderChanges: [schema.removeMissingTracks.key, schema.rescanModifiedFiles.key]
            case .libraryFolder:
                [
                    schema.copyAddedFiles.key, schema.keepFilesOrganized.key,
                    schema.libraryFolder.key,
                ]
            case .networkFolders:
                [schema.pausePollingDuringPlayback.key, schema.rescanNetworkFoldersAtLaunch.key]
            // `appearance` is every appearance key's prefix, so a new one shows here until it's
            // given a section.
            case .theme: [schema.appearance.key, schema.glass.key]
            case .trackTable:
                [
                    schema.columnLines.key, schema.rowLines.key, schema.albumLines.key,
                    schema.rowLineColor.key, schema.albumLineColor.key,
                    schema.playingRowColor.key, schema.alternatingRows.key, schema.rowHeight.key,
                    schema.artSize.key,
                ]
            case .titles: [schema.windowTitle.key, schema.headerTitleFormat.key]
            case .toolbarStatus:
                [schema.headerStatusLayout.key] + schema.customStatusLayouts.map(\.key)
            case .statusBar:
                [
                    schema.statusBarStyle.key, schema.statusBarLayout.key,
                    schema.totalsFormat.key, schema.totalsListAndSelectionFormat.key,
                    schema.totalsListFormat.key, schema.totalsSelectionFormat.key,
                    schema.downloadsStatusStyle.key,
                ]
            case .other: []
            }
        }

        /// The checkboxes that turn the section's other settings on; they're disabled while
        /// every one is off, so the box reads as what depends on what.
        var switchKeys: [String] {
            return switch self {
            case .receiver: [schema.receiverEnabled.key]
            case .libraryFolder: [schema.copyAddedFiles.key, schema.keepFilesOrganized.key]
            default: []
            }
        }

        /// Each section's prefixes, read once: a pane looks up the section of each of its rows.
        private static let allPrefixes = allCases.map { ($0, $0.prefixes) }

        init(key: String) {
            let matches = Self.allPrefixes.flatMap { section, prefixes in
                prefixes.filter { key.hasPrefix($0) }.map { (section, $0.count) }
            }
            self = matches.max { $0.1 < $1.1 }?.0 ?? .other
        }
    }

    /// A row for each setting the window shows; the rest are edited in the config file.
    public let rows: [Row]
    /// The sections in order, each with its rows in schema order; the Watched Folders pane
    /// shows the watched folders in a list of their own.
    var sections: [(section: Section, rows: [Row])] {
        let shown = Dictionary(
            grouping: rows.filter { ![.folders, .renderer].contains($0.control) },
            by: { Section(key: $0.key) })
        return Section.allCases.compactMap { section in
            shown[section].map { (section, $0) }
        }
    }
    /// The watched folders' row, which the Watched Folders pane shows.
    var foldersRow: Row? { rows.first { $0.control == .folders } }
    /// The template settings by key, each of which checks its own tokens.
    private let templates: [String: SettingDescriptor]
    private let value: (String) -> Any?
    private let set: (String, Any) throws -> Void
    /// Whether the config file refuses every change until it's fixed (ADR 0082).
    let isBlocked: () -> Bool

    /// `value` reads a setting as JSON holds it; `set` writes one. `searcherInstalled` says
    /// whether the File Viewer setting has a choice to make; `isBlocked` whether the config file
    /// refuses changes.
    public init(
        settings: [SettingDescriptor], searcherInstalled: Bool, value: @escaping (String) -> Any?,
        set: @escaping (String, Any) throws -> Void, isBlocked: @escaping () -> Bool
    ) {
        rows = settings.filter {
            $0.kind != .windowState && Self.isShown($0.key, searcherInstalled: searcherInstalled)
        }
        .map(Self.row)
        templates = Dictionary(
            uniqueKeysWithValues: settings.compactMap {
                guard case .template = $0.kind else { return nil }
                return ($0.key, $0)
            })
        self.value = value
        self.set = set
        self.isBlocked = isBlocked
    }

    /// Whether the window has a row for the setting. State the app writes, such as the play
    /// state, has none (`.windowState`). Network Scan Readers is a tuning number
    /// few would understand, and File Viewer has nothing to pick without Searcher, so both stay
    /// in the config file (ADR 0067). The Discogs window picks the dumps folder, and the
    /// catalog's path is for a Mac short of space, so both are edited there or in the file
    /// (ADR 0130); the field mappings are edited in its Field Mapping sheet, and its choices
    /// beside it (ADR 0132). The Discogs and service tokens are secrets, kept in the file only
    /// (ADR 0137, ADR 0144).
    private static func isShown(_ key: String, searcherInstalled: Bool) -> Bool {
        return switch key {
        case schema.networkScanReaders.key, schema.discogsDumpsFolder.key,
            schema.discogsCatalogPath.key, schema.discogsToken.key, schema.discogsMapping.key,
            schema.discogsSavedMappings.key, schema.discogsKeepExistingValues.key,
            schema.discogsSkipVideo.key, schema.discogsFillSortArtist.key,
            schema.discogsArtwork.key, schema.recommenderToken.key:
            false
        case schema.fileViewer.key: searcherInstalled
        default: true
        }
    }

    private static func row(_ setting: SettingDescriptor) -> Row {
        let control: Control =
            switch setting.kind {
            case _ where setting.key == schema.outputDeviceUID.key: .output
            case _ where setting.key == schema.outputRenderer.key: .renderer
            case _ where setting.key == schema.libraryFolder.key:
                .folder(
                    emptyText: noValueText,
                    message: "Choose the folder that files added to the library are copied into."
                        + " Only Keep Files Organized renames the files already in it.")
            case _ where setting.key == schema.snapshotFolder.key:
                .folder(
                    emptyText: "Backups, beside the library",
                    message: "Choose a folder outside your music for the library's daily"
                        + " snapshots. The app writes only its snapshots there.")
            case .bool: .checkbox
            case .choice(let choices): .popUp(choices)
            case .integer: .number(whole: true, optional: false)
            case .optional(.integer): .number(whole: true, optional: true)
            case .number: .number(whole: false, optional: false)
            case .optional(.number): .number(whole: false, optional: true)
            case .string: .text(optional: false)
            case .optional(.string): .text(optional: true)
            case .template(let tokens): .template(tokens)
            case .list(.watchedFolder): .folders
            case .optional(.syncFolder): .syncFolder
            case .optional(.stagingFolder): .stagingFolder
            case .barLayout(let bar):
                .barLayout(bar, defaultLayout: barLayout(setting.defaultValue))
            case .color: .color(optional: false)
            case .optional(.color): .color(optional: true)
            default: .readOnly
            }
        return Row(
            key: setting.key, title: setting.title, summary: setting.summary, control: control,
            unit: setting.key == schema.playedPercent.key ? "%" : nil,
            disclosure: setting.key == schema.receiverAddress.key
                ? "Can't find the receiver?" : nil,
            group: schema.customStatusLayouts.firstIndex { $0.key == setting.key }.map(
                RowGroup.customStatus),
            address: [schema.recommenderAddress.key, schema.receiverAddress.key].contains(
                setting.key) ? addressPlaceholder : nil)
    }

    /// Why a change was refused, without the config file's path and the key, which the row
    /// already shows: "\"http://192.0.2.1\" isn't an IPv4 or IPv6 address; host names aren't
    /// taken".
    static func refusal(_ error: any Error) -> String {
        guard case .invalid(_, let problems) = error as? SettingsError, !problems.isEmpty else {
            return "\(error)"
        }
        let reasons = problems.map { "\($0.reason)" }.joined(separator: "; ")
        return reasons.prefix(1).uppercased() + reasons.dropFirst()
    }

    /// Whether a row can be changed now: not while its section's switches are all off.
    func isEnabled(_ key: String) -> Bool {
        let switches = Section(key: key).switchKeys
        guard !switches.isEmpty, !switches.contains(key) else { return true }
        return switches.contains(where: isOn)
    }

    public func isOn(_ key: String) -> Bool { value(key) as? Bool == true }

    public func choice(_ key: String) -> String? { value(key) as? String }

    /// The output the config names, as the output device's row shows it picked.
    var output: OutputChoice {
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

    /// The sync or staging folder as `folders` shows a folder; nil for none.
    public func syncFolder(_ key: String) -> String? {
        (value(key) as? [String: Any]).flatMap(folderText)
    }

    /// The sync or staging folder's own name, or its share's for the share itself; nil for
    /// none.
    func syncFolderName(_ key: String) -> String? {
        guard let folder = value(key) as? [String: Any], let path = folder["path"] as? String
        else { return nil }
        guard path.isEmpty, let share = folder["share"] as? String else {
            return (path as NSString).lastPathComponent
        }
        return URL(string: share)?.lastPathComponent ?? share
    }

    /// The bar builder's model for the bar layout row `key`.
    func barBuilder(_ key: String) throws -> BarBuilderModel {
        guard let row = rows.first(where: { $0.key == key }),
            case .barLayout(let bar, let defaultLayout) = row.control
        else { preconditionFailure("\(key) isn't a bar layout") }
        return try BarBuilderModel(
            key: key, title: row.title, bar: bar, defaultLayout: defaultLayout,
            value: { [value] in value(key) },
            set: { [set] json in try set(key, json) }, blocked: isBlocked)
    }

    func clear(_ key: String) throws { try set(key, NSNull()) }

    /// Why `text` isn't a template for the setting `key`, with its tokens, as `setText` would
    /// refuse it; nil when it parses.
    func templateProblem(_ key: String, _ text: String) -> String? {
        guard let setting = templates[key] else {
            preconditionFailure("\(key) isn't a template")
        }
        return setting.problem(text.trimmingCharacters(in: .whitespaces))
    }

    /// The default a template row's Reset to Default puts back.
    func templateDefault(_ key: String) -> String {
        guard let setting = templates[key] else {
            preconditionFailure("\(key) isn't a template")
        }
        return templateText(setting.defaultValue)
    }

    /// Saves the template row `key`'s default, as typing it would.
    func resetTemplate(_ key: String) throws { try setText(key, templateDefault(key)) }

    /// A template's tokens, one a line with what each stands for, for its help button's
    /// tooltip and popover.
    static func help(_ tokens: [SettingKind.Token]) -> String {
        tokens.map { "\($0.name)  \($0.help)" }.joined(separator: "\n")
    }

    /// A color row's color; nil for null, or for text that isn't a color, which the config
    /// file refuses before it reaches here.
    func color(_ key: String) -> HexColor? {
        (value(key) as? String).map { HexColor($0) }.flatMap { $0.components == nil ? nil : $0 }
    }

    func setColor(_ key: String, _ color: HexColor) throws { try set(key, color.text) }

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
        case .folder:
            try set(key, trimmed.isEmpty ? NSNull() : trimmed)
        case .template:
            // Saved as it's typed, so a keystroke that leaves the template as it is, a space
            // at the end, writes nothing.
            guard trimmed != self.text(key) else { return }
            try set(key, trimmed)
        case .checkbox, .popUp, .folders, .syncFolder, .stagingFolder, .output, .renderer,
            .barLayout, .color,
            .readOnly:
            preconditionFailure("\(key) isn't a text row")
        }
    }
}

/// A bar layout setting's value with its parts by their names in the config file, as the bar
/// builder holds them.
private func barLayout(_ value: any SettingValue) -> BarLayout<String> {
    do {
        return try JSONDecoder().decode(
            BarLayout<String>.self, from: JSONEncoder().encode(value))
    } catch {
        preconditionFailure("a bar layout's default doesn't read back: \(error)")
    }
}

/// A template setting's value as its row's field shows it.
private func templateText(_ value: any SettingValue) -> String {
    do {
        return try JSONDecoder().decode(String.self, from: JSONEncoder().encode(value))
    } catch {
        preconditionFailure("a template's default doesn't read back: \(error)")
    }
}

/// A folder as the config file holds it, by path or by share and the path inside it.
private func folderText(_ folder: [String: Any]) -> String? {
    guard let path = folder["path"] as? String else { return nil }
    guard let share = folder["share"] as? String else { return path }
    return path.isEmpty ? share : "\(path) on \(share)"
}
