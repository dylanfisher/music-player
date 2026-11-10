import CoreServices
import Foundation
import Log

private let logger = moduleLogger()

/// The config file's name, in `~/.config/music-player` or a `--home` folder.
public let configFileName = "config.json"

/// `~/.config/music-player/config.json`.
func defaultConfigFileURL() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/music-player").appendingPathComponent(configFileName)
}

/// The settings in effect, read from and written to the config file, which is the settings:
/// every preference and the user's shortcuts. Changes in the app are patches to the file's text;
/// saves in an editor are read back as they happen. A file whose only problems are unknown keys
/// applies the rest and takes patches. A file with any other problem applies nothing, and the
/// app's changes are refused until it's fixed (ADR 0082).
@MainActor
public final class ConfigStore<Schema: SettingsSchema> {
    /// How long a file found empty or gone waits for a second read, since an editor's save in
    /// place and a sync tool's delete and create pass through both.
    static var confirmSeconds: Double { 0.2 }
    static var firstRetrySeconds: Double { 1 }
    static var longestRetrySeconds: Double { 30 }

    public let schema: Schema
    public let fileURL: URL
    private let descriptors: [SettingDescriptor]
    private let byKey: [String: SettingDescriptor]
    private let check: ShortcutCheck
    private var values: [String: any SettingValue] = [:]
    public private(set) var shortcuts: ShortcutOverrides = [:]
    /// What's wrong with the file as last read; empty when it's good or missing.
    public private(set) var problems: [ConfigProblem] = []
    /// The keys whose value the file or `set` gave, not a default.
    private var given: Set<String> = []
    /// Why the last write failed, until one succeeds.
    public private(set) var writeFailure: String?
    /// Called with the keys whose values changed, `ConfigFile.shortcutsKey` for the shortcuts.
    public var changed: (Set<String>) -> Void = { _ in }
    /// Called when `problems` or `writeFailure` changes, for the banner.
    public var problemsChanged: () -> Void = {}

    private enum Patch {
        case setting(String, any SettingValue)
        case shortcut(String, ShortcutOverride)
    }

    /// Changes made in the app that aren't in the file yet, in order.
    private var pending: [Patch] = []
    /// The file's bytes as last read or written; nil for no file.
    private var lastBytes: [UInt8]?
    private var confirming = false
    /// The wait before the last retry of a failed write, and whether one is scheduled.
    private(set) var retrySeconds: Double?
    private var retryScheduled = false
    /// Runs a retry on the main queue after a wait; tests run them without waiting.
    var runAfter: (Double, @escaping () -> Void) -> Void = { seconds, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
    private var watch: DirectoryWatch?

    /// Reads `fileURL`. With `creating`, a missing file is written with every default. A file
    /// with problems that block it leaves the defaults in effect; `problems` lists them.
    public init(_ schema: Schema, fileURL: URL, check: @escaping ShortcutCheck, creating: Bool) {
        self.schema = schema
        self.fileURL = fileURL
        self.check = check
        descriptors = schema.settings
        byKey = Dictionary(descriptors.map { ($0.key, $0) }) { first, _ in
            preconditionFailure("two settings share the key \"\(first.key)\"")
        }
        values = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.key, $0.defaultValue) })
        removeLeftoverAtomicWrites(beside: fileURL.resolvingSymlinksInPath())
        read(confirmed: true)
        if creating, lastBytes == nil, problems.isEmpty { writeNewFile() }
    }

    /// Reads the file for a command-line mode, which has no banner: a file with any problem
    /// throws.
    public static func strict(_ schema: Schema, fileURL: URL, check: @escaping ShortcutCheck)
        throws -> ConfigStore
    {
        let store = ConfigStore(schema, fileURL: fileURL, check: check, creating: false)
        guard store.problems.isEmpty else {
            throw ConfigError(path: fileURL.path, problems: store.problems)
        }
        return store
    }

    public subscript<Value>(_ setting: KeyPath<Schema, Setting<Value>>) -> Value {
        values[schema[keyPath: setting].key] as! Value
    }

    /// The setting's value when the file or a change in the app gave it; nil while it's the
    /// default because the file doesn't apply, is gone, or doesn't name it. For a value acted
    /// on in a way a default must never be, such as removing the files outside the watched
    /// folders.
    public func fileValue<Value>(_ setting: KeyPath<Schema, Setting<Value>>) -> Value? {
        given.contains(schema[keyPath: setting].key) ? self[setting] : nil
    }

    /// How many times a read found the file's contents changed by something other than the
    /// app, such as an editor's save; a reread of an unchanged file, or the app's own patch,
    /// doesn't count. The banner keeps a dismissed problem hidden until it moves.
    public private(set) var edits = 0
    /// `edits` when `problemsChanged` was last called.
    private var reportedEdits = 0

    /// Whether the file applies nothing until it's fixed, as opposed to skipping unknown keys.
    public var blocked: Bool { problems.contains(where: \.blocks) }

    /// A setting's value as JSON holds it, such as `true` or `"dark"`, for code that knows the
    /// setting only by its key.
    public func json(forKey key: String) -> Any? {
        guard let value = values[key] else { return nil }
        return try! JSONSerialization.jsonObject(
            with: Data(jsonText(value).utf8), options: .fragmentsAllowed)
    }

    /// Whether the bool setting `key` is on.
    public func isOn(_ key: String) -> Bool { json(forKey: key) as? Bool == true }

    /// The text of a new file, and of Copy Default Config.
    public var defaultText: String { ConfigFile.defaultText(settings: descriptors) }

    /// Validates `value`, uses it at once, and writes it to the file.
    public func set<Value>(_ setting: KeyPath<Schema, Setting<Value>>, to value: Value) throws {
        let setting = schema[keyPath: setting]
        if let reason = setting.validate(value) {
            throw ConfigError(
                path: fileURL.path,
                problems: [ConfigProblem(line: nil, message: "\"\(setting.key)\": \(reason)")])
        }
        try checkConflicts(setting.key, value)
        try apply(.setting(setting.key, value))
    }

    /// Throws what setting `key` to `value` would conflict with, leaving the settings as they
    /// are.
    private func checkConflicts(_ key: String, _ value: any SettingValue) throws {
        var next = values
        next[key] = value
        let conflicts = schema.conflicts(next)
        guard conflicts.isEmpty else {
            throw ConfigError(
                path: fileURL.path,
                problems: conflicts.map {
                    ConfigProblem(line: nil, message: "\"\($0.key)\": \($0.reason)")
                })
        }
    }

    /// Sets the setting `key` from a value as JSON holds it, such as `true` or `"dark"`.
    public func set(key: String, json: Any) throws {
        guard let descriptor = byKey[key] else {
            preconditionFailure("\(key) isn't a setting")
        }
        switch descriptor.decode(json) {
        case .success(let value):
            try checkConflicts(key, value)
            try apply(.setting(key, value))
        case .failure(let reason):
            throw ConfigError(
                path: fileURL.path,
                problems: [ConfigProblem(line: nil, message: "\"\(key)\": \(reason)")])
        }
    }

    /// Sets command `id`'s shortcut overrides; an empty override goes back to the defaults.
    public func setShortcut(_ id: String, to override: ShortcutOverride) throws {
        try apply([.shortcut(id, override)])
    }

    /// Sets several commands' overrides as one change, so a chord moving from one command to
    /// another is never seen half done.
    public func setShortcuts(_ overrides: [String: ShortcutOverride]) throws {
        try apply(overrides.sorted { $0.key < $1.key }.map { .shortcut($0.key, $0.value) })
    }

    private func apply(_ patch: Patch) throws { try apply([patch]) }

    /// Takes `patches` and writes them. Refused while a problem blocks the file: the values in
    /// memory are defaults then, so a change built on them, written when the file is fixed,
    /// would replace what the file has, such as the watched folders (ADR 0082).
    private func apply(_ patches: [Patch]) throws {
        if let problem = problems.first(where: \.blocks) {
            throw ConfigError(
                path: fileURL.path,
                problems: [
                    ConfigProblem(
                        line: nil,
                        message: "nothing can change until the file is fixed: \(problem)")
                ])
        }
        var keys: Set<String> = []
        for patch in patches {
            keys.formUnion(take(patch))
            pending.removeAll { same($0, patch) }
            pending.append(patch)
        }
        if !keys.isEmpty { changed(keys) }
        flush()
    }

    /// Puts `patch` in memory; the keys it changed.
    private func take(_ patch: Patch) -> Set<String> {
        switch patch {
        case .setting(let key, let value):
            given.insert(key)
            guard values[key].map({ !value.isEqual(to: $0) }) ?? true else { return [] }
            values[key] = value
            return [key]
        case .shortcut(let id, let override):
            let old = shortcuts[id] ?? ShortcutOverride()
            guard old != override else { return [] }
            shortcuts[id] = override.isEmpty ? nil : override
            return [ConfigFile.shortcutsKey]
        }
    }

    private func same(_ a: Patch, _ b: Patch) -> Bool {
        switch (a, b) {
        case (.setting(let x, _), .setting(let y, _)): x == y
        case (.shortcut(let x, _), .shortcut(let y, _)): x == y
        default: false
        }
    }

    // MARK: Reading

    /// Starts reading the file again whenever it or its folder changes. A symbolic link's
    /// target folder is watched too.
    public func startWatching() {
        let target = fileURL.resolvingSymlinksInPath()
        let folders = Set([fileURL, target].map { $0.deletingLastPathComponent().path })
        watch = DirectoryWatch(folders: Array(folders)) { [weak self] in
            self?.read(confirmed: false)
        }
    }

    /// Reads the file and applies it if it changed. A file found empty or gone where it wasn't
    /// is read again a moment later before that counts.
    func read(confirmed: Bool) {
        let bytes: [UInt8]?
        do {
            bytes = try currentBytes()
        } catch {
            setProblems([ConfigProblem(line: nil, message: "can't read the file: \(error)")])
            return
        }
        // A chmod that makes a withheld secret usable changes no bytes, so it's checked too.
        if bytes == lastBytes, !confirmed || lastBytes != nil,
            !problems.contains(where: \.isWarning) || othersCanRead(fileURL)
        {
            // Changes made while an empty read waited for confirmation go in now.
            flush()
            return
        }
        let vanished = bytes == nil || bytes!.allSatisfy { [0x20, 0x09, 0x0A, 0x0D].contains($0) }
        if vanished, !confirmed, lastBytes != nil {
            guard !confirming else { return }
            confirming = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.confirmSeconds) { [weak self] in
                self?.confirming = false
                self?.read(confirmed: true)
            }
            return
        }
        if bytes != lastBytes { edits += 1 }
        lastBytes = bytes
        guard let bytes else {
            logger.notice("\(self.fileURL.path) is gone; using the defaults")
            replace(with: ConfigContents(values: [:], shortcuts: [:]))
            setProblems([])
            if !pending.isEmpty { writeNewFile() }
            return
        }
        if apply(bytes) { flush() }
    }

    /// Applies `bytes` unless a problem blocks them; whether it did.
    private func apply(_ bytes: [UInt8]) -> Bool {
        do {
            let contents = try ConfigFile.parse(
                ConfigText(bytes: bytes), settings: descriptors, check: check,
                conflicts: schema.conflicts, othersCanRead: othersCanRead(fileURL))
            if let first = contents.skipped.first {
                logger.notice(
                    "\(self.fileURL.path): skipped \(contents.skipped.count) unknown keys, first \(first)"
                )
            }
            replace(with: contents)
            setProblems(contents.skipped)
            return true
        } catch {
            for problem in error.problems { logger.error("\(self.fileURL.path): \(problem)") }
            setProblems(error.problems)
            return false
        }
    }

    /// The file's bytes; nil when there is no file. Throws when there is one it can't read.
    private func currentBytes() throws -> [UInt8]? {
        do {
            return try [UInt8](Data(contentsOf: fileURL))
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
    }

    /// Makes `contents` the settings, with the changes not yet written on top, and reports the
    /// keys that changed.
    private func replace(with contents: ConfigContents) {
        let oldValues = values
        let oldShortcuts = shortcuts
        let oldGiven = given
        given = Set(contents.values.keys)
        values = Dictionary(
            uniqueKeysWithValues: descriptors.map {
                ($0.key, contents.values[$0.key] ?? $0.defaultValue)
            })
        shortcuts = contents.shortcuts.filter { !$0.value.isEmpty }
        for patch in pending { _ = take(patch) }
        // A value the file now gives, or no longer does, counts as changed even when it's the
        // same, so what `fileValue` gates runs again.
        var keys = Set(
            descriptors.map(\.key).filter { !values[$0]!.isEqual(to: oldValues[$0]!) }
        ).union(given.symmetricDifference(oldGiven))
        if shortcuts != oldShortcuts { keys.insert(ConfigFile.shortcutsKey) }
        if !keys.isEmpty { changed(keys) }
    }

    private func setProblems(_ new: [ConfigProblem]) {
        // An edit that keeps the same problems is reported too: a warning closed in the banner
        // shows again after one.
        guard new != problems || (!new.isEmpty && reportedEdits != edits) else { return }
        problems = new
        reportedEdits = edits
        problemsChanged()
    }

    // MARK: Writing

    /// Writes the waiting changes on top of the file as it is now. Nothing is written over a
    /// file a problem blocks, or one whose empty or missing read isn't confirmed yet. Over one
    /// with unknown keys, the patches change only their own keys' text.
    private func flush() {
        guard !pending.isEmpty, !blocked, !confirming, !retryScheduled else { return }
        do {
            let current = try currentBytes()
            if current != lastBytes {
                // An edit not read yet; it applies first, and the changes go on top.
                read(confirmed: true)
                return
            }
            guard let current else {
                writeNewFile()
                return
            }
            var text = ConfigText(bytes: current)
            for patch in pending { text = try patched(text, patch) }
            try write(text.bytes)
        } catch {
            failed(error) { $0.flush() }
        }
    }

    private func writeNewFile() {
        do {
            var text = ConfigText(defaultText)
            for patch in pending { text = try patched(text, patch) }
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try write(text.bytes)
            logger.info("wrote a new config file at \(self.fileURL.path)")
            // The file names every key now. An empty list of watched folders removes nothing
            // (ADR 0082), so its defaults can count as given.
            let newlyGiven = Set(descriptors.map(\.key)).subtracting(given)
            given.formUnion(newlyGiven)
            if !newlyGiven.isEmpty { changed(newlyGiven) }
        } catch {
            // There may be no changes waiting, so the retry writes the new file itself, unless
            // one has appeared meanwhile.
            failed(error) { $0.retryNewFile() }
        }
    }

    private func retryNewFile() {
        do {
            if try currentBytes() == nil {
                writeNewFile()
            } else {
                read(confirmed: true)
            }
        } catch {
            failed(error) { $0.retryNewFile() }
        }
    }

    private func patched(_ text: ConfigText, _ patch: Patch) throws -> ConfigText {
        switch patch {
        case .setting(let key, let value):
            try ConfigFile.patch(text, setting: byKey[key]!, to: value)
        case .shortcut(let id, let override):
            try ConfigFile.patch(text, shortcut: id, to: override)
        }
    }

    /// Writes through a symbolic link to the file it leads to, so the link stays a link, at
    /// mode 0600. A file with problems is read again, since their lines can move, and a secret
    /// withheld for its mode is used from then on.
    private func write(_ bytes: [UInt8]) throws {
        try writeConfigFile(bytes, to: fileURL.resolvingSymlinksInPath())
        lastBytes = bytes
        pending = []
        retrySeconds = nil
        if writeFailure != nil {
            writeFailure = nil
            problemsChanged()
        }
        if !problems.isEmpty { _ = apply(bytes) }
    }

    /// Remove Obsolete Setting: takes each unknown key out of the file, with its line and the
    /// comment lines directly above it, and leaves the rest of the text as it is (ADR 0082).
    /// Changes waiting on a failed write keep waiting.
    public func removeObsoleteKeys() throws {
        if try currentBytes() != lastBytes { read(confirmed: true) }
        let paths = problems.compactMap(\.obsoleteKey)
        guard !paths.isEmpty, let bytes = lastBytes else { return }
        var text = ConfigText(bytes: bytes)
        for path in paths { text = try ConfigFile.removing(path, from: text) }
        let waiting = pending
        try write(text.bytes)
        logger.notice(
            "removed \(paths.map { $0.joined(separator: ".") }) from \(self.fileURL.path)")
        pending = waiting
        flush()
    }

    /// Keeps the changes waiting and runs `retry` later, waiting longer each time.
    private func failed(_ error: any Error, retry: @escaping (ConfigStore) -> Void) {
        logger.error("couldn't write \(self.fileURL.path): \(error)")
        writeFailure = "\(error)"
        problemsChanged()
        let wait = Self.nextRetry(after: retrySeconds)
        retrySeconds = wait
        retryScheduled = true
        runAfter(wait) { [weak self] in
            guard let self else { return }
            retryScheduled = false
            retry(self)
        }
    }

    /// The wait before a retry, after one of `previous` seconds or none: doubling, up to
    /// `longestRetrySeconds`.
    static func nextRetry(after previous: Double?) -> Double {
        previous.map { min($0 * 2, longestRetrySeconds) } ?? firstRetrySeconds
    }

    /// Writes a new file if there is none, for Open Config File. Throws when it can't.
    public func createIfMissing() throws {
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        writeNewFile()
        if let writeFailure { throw ConfigProblem(line: nil, message: writeFailure) }
    }
}

/// Calls back on the main queue when anything in one of `folders` changes, through FSEvents,
/// which also reports a folder created after the watch starts.
final class DirectoryWatch {
    private var stream: FSEventStreamRef?
    private let box: Box

    /// Read only on the main queue, where FSEvents calls back.
    private final class Box: @unchecked Sendable {
        let changed: @MainActor () -> Void
        init(_ changed: @escaping @MainActor () -> Void) { self.changed = changed }
    }

    init(folders: [String], changed: @escaping @MainActor () -> Void) {
        box = Box(changed)
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(box).toOpaque(), retain: nil, release: nil,
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { box.changed() }
        }
        guard
            let stream = FSEventStreamCreate(
                kCFAllocatorDefault, callback, &context, folders as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05,
                FSEventStreamCreateFlags(
                    kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
        else {
            logger.error(
                "FSEvents refused to watch \(folders); config edits apply at the next launch")
            return
        }
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            logger.error(
                "FSEvents couldn't watch \(folders); config edits apply at the next launch")
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        self.stream = stream
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
