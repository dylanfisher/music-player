import Foundation
import Log

private let logger = moduleLogger()

/// `~/Library/Application Support/MusicPlayer/settings.json`.
public func defaultSettingsFileURL() throws -> URL {
    try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
    ).appendingPathComponent("\(appDirectoryName)/settings.json")
}

/// The settings in effect: the schema's defaults overridden by the values in a JSON file. The file
/// holds only values that differ from their defaults. Safe to use from any thread.
public final class SettingsStore<Schema: SettingsSchema>: @unchecked Sendable {
    public let schema: Schema
    public let fileURL: URL
    private let descriptors: [SettingDescriptor]
    private let byKey: [String: SettingDescriptor]
    private let lock = NSLock()
    private var overrides: [String: any SettingValue]

    /// Reads `fileURL`. A missing file means nothing has been changed; a file that doesn't match
    /// the schema throws, naming every bad key.
    public init(_ schema: Schema, fileURL: URL) throws {
        self.schema = schema
        self.fileURL = fileURL
        descriptors = schema.settings
        byKey = Dictionary(descriptors.map { ($0.key, $0) }) { first, _ in
            preconditionFailure("two settings share the key \"\(first.key)\"")
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch CocoaError.fileReadNoSuchFile {
            overrides = [:]
            logger.info("no settings file at \(fileURL.path), using defaults")
            return
        } catch {
            throw SettingsError.unreadable(path: fileURL.path, reason: "\(error)")
        }
        overrides = try parse(data, path: fileURL.path, settings: byKey)
        logger.info("loaded \(self.overrides.count) changed settings from \(fileURL.path)")
    }

    public subscript<Value>(_ setting: KeyPath<Schema, Setting<Value>>) -> Value {
        let setting = schema[keyPath: setting]
        return lock.withLock { overrides[setting.key] }.map { $0 as! Value } ?? setting.defaultValue
    }

    /// Validates `value` and saves it. Setting a value back to its default removes it from the file.
    public func set<Value>(_ setting: KeyPath<Schema, Setting<Value>>, to value: Value) throws {
        let setting = schema[keyPath: setting]
        if let reason = setting.validate(value) {
            throw SettingsError.invalid(
                path: nil, problems: [SettingProblem(key: setting.key, reason: reason)])
        }
        try update { $0[setting.key] = value }
    }

    /// Every setting with its current value, defaults included, as pretty-printed JSON.
    public func exportJSON() throws -> Data {
        let effective = lock.withLock { overrides }
        return try serialize(
            Dictionary(
                uniqueKeysWithValues: try descriptors.map { descriptor in
                    let value = effective[descriptor.key] ?? descriptor.defaultValue
                    return (descriptor.key, try json(value))
                }))
    }

    public func export(to url: URL) throws {
        try exportJSON().write(to: url, options: .atomic)
        logger.info("exported settings to \(url.path)")
    }

    /// Applies the values in `url` on top of the current ones, after validating the whole file the
    /// way `init` does. Keys the file leaves out keep their values. Nothing changes if any key is
    /// bad. Returns how many values the file held.
    @discardableResult
    public func importSettings(from url: URL) throws -> Int {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw SettingsError.unreadable(path: url.path, reason: "\(error)")
        }
        let imported = try parse(data, path: url.path, settings: byKey)
        try update { $0.merge(imported) { _, new in new } }
        logger.info("imported \(imported.count) settings from \(url.path)")
        return imported.count
    }

    /// Changes a copy of the overrides, writes it, and only then makes it current, so a failed
    /// write leaves the store matching the file.
    private func update(_ change: (inout [String: any SettingValue]) -> Void) throws {
        try lock.withLock {
            var next = overrides
            change(&next)
            next = next.filter { key, value in !value.isEqual(to: byKey[key]!.defaultValue) }
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try serialize(try next.mapValues { try json($0) }).write(to: fileURL, options: .atomic)
            overrides = next
        }
    }
}

/// Decodes and validates a settings file, collecting every bad key before throwing.
private func parse(
    _ data: Data, path: String, settings byKey: [String: SettingDescriptor]
) throws -> [String: any SettingValue] {
    let object: Any
    do {
        object = try JSONSerialization.jsonObject(with: data)
    } catch {
        throw SettingsError.notJSON(path: path, reason: "\(error)")
    }
    guard let entries = object as? [String: Any] else {
        throw SettingsError.notAnObject(path: path)
    }
    var values: [String: any SettingValue] = [:]
    var problems: [SettingProblem] = []
    for (key, json) in entries.sorted(by: { $0.key < $1.key }) {
        guard let descriptor = byKey[key] else {
            problems.append(SettingProblem(key: key, reason: .unknownKey))
            continue
        }
        switch descriptor.decode(json) {
        case .success(let value): values[key] = value
        case .failure(let reason): problems.append(SettingProblem(key: key, reason: reason))
        }
    }
    guard problems.isEmpty else { throw SettingsError.invalid(path: path, problems: problems) }
    return values
}

/// A value as `JSONSerialization` holds it.
private func json(_ value: some SettingValue) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: .fragmentsAllowed)
}

private func serialize(_ entries: [String: Any]) throws -> Data {
    try JSONSerialization.data(
        withJSONObject: entries, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        + Data("\n".utf8)
}
