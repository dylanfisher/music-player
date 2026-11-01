import Foundation
import Log

private let logger = moduleLogger()

/// App state in effect: the schema's defaults overridden by the values in a JSON file, which holds
/// only values that differ from their defaults. A file that doesn't match the schema is logged and
/// discarded whole, and the next save writes over it: it holds only where the user left things,
/// and stored data has one shape before release. Safe to use from any thread.
public final class StateStore<Schema: SettingsSchema>: @unchecked Sendable {
    public let schema: Schema
    public let fileURL: URL
    /// Why the file was discarded when it was read, for the window to show; nil when it decoded
    /// or wasn't there.
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
            overrides = try parse(data, path: fileURL.path, settings: byKey)
            discardReason = nil
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
    public func set<Value>(_ setting: KeyPath<Schema, Setting<Value>>, to value: Value) throws {
        let setting = schema[keyPath: setting]
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

/// Decodes and validates a settings file, collecting every bad key before throwing.
func parse(
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
