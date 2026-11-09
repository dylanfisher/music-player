import Foundation
import Log

private let logger = moduleLogger()

/// App state in effect: the schema's defaults overridden by the values in a JSON file, which holds
/// only values that differ from their defaults. A key the schema doesn't have, or whose value
/// doesn't match, is logged and dropped, and the rest of the file is kept; a file that isn't a JSON
/// object is dropped whole. The next save writes over what was dropped: stored data has one shape
/// before release, but one stale key mustn't cost the whole layout. Safe to use from any thread.
public final class StateStore<Schema: SettingsSchema>: @unchecked Sendable {
    public let schema: Schema
    public let fileURL: URL
    /// What was dropped when the file was read, and why, for the window to show: the keys that
    /// didn't match, or the whole file. Nil when it all decoded or wasn't there.
    public let discardReason: String?
    private let descriptors: [SettingDescriptor]
    private let byKey: [String: SettingDescriptor]
    private let lock = NSLock()
    private var overrides: [String: any SettingValue]

    /// Reads `fileURL`. A missing file means nothing has been changed. Throws only when the file
    /// is there but can't be read.
    public init(_ schema: Schema, fileURL: URL) throws {
        self.schema = schema
        self.fileURL = fileURL
        descriptors = schema.settings
        byKey = Dictionary(descriptors.map { ($0.key, $0) }) { first, _ in
            preconditionFailure("two settings share the key \"\(first.key)\"")
        }
        removeLeftoverAtomicWrites(beside: fileURL)
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch CocoaError.fileReadNoSuchFile {
            overrides = [:]
            discardReason = nil
            logger.info("no state file at \(fileURL.path), using defaults")
            return
        } catch {
            throw SettingsError.unreadable(path: fileURL.path, reason: "\(error)")
        }
        do {
            let parsed = try parse(data, path: fileURL.path, settings: byKey)
            overrides = parsed.values
            discardReason = parsed.dropped.map { "\($0)" }
            if let dropped = parsed.dropped {
                logger.error("dropped from the state file, not matching this build: \(dropped)")
            }
        } catch {
            logger.error("discarded \(fileURL.path), which doesn't match this build: \(error)")
            overrides = [:]
            discardReason = "\(error)"
            return
        }
        logger.info("loaded \(self.overrides.count) saved values from \(fileURL.path)")
    }

    public subscript<Value>(_ setting: KeyPath<Schema, Setting<Value>>) -> Value {
        let setting = schema[keyPath: setting]
        return lock.withLock { overrides[setting.key] }.map { $0 as! Value } ?? setting.defaultValue
    }

    /// Validates `value` and saves it. Setting a value back to its default removes it from the file.
    /// A value equal to the one in effect writes nothing: the window reports its state at every
    /// change, a library refresh during a scan included.
    public func set<Value>(_ keyPath: KeyPath<Schema, Setting<Value>>, to value: Value) throws {
        guard self[keyPath] != value else { return }
        let setting = schema[keyPath: keyPath]
        if let reason = setting.validate(value) {
            throw SettingsError.invalid(
                path: nil, problems: [SettingProblem(key: setting.key, reason: reason)])
        }
        try update { $0[setting.key] = value }
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

/// Decodes and validates a settings file: the values that match, and every bad key at once as
/// `SettingsError.invalid`. Throws only when the file isn't a JSON object.
func parse(
    _ data: Data, path: String, settings byKey: [String: SettingDescriptor]
) throws -> (values: [String: any SettingValue], dropped: SettingsError?) {
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
    return (values, problems.isEmpty ? nil : SettingsError.invalid(path: path, problems: problems))
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
