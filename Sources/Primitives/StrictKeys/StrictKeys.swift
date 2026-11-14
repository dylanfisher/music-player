/// `decoder`'s object, checked to have no key outside `Keys`, so a misspelled field fails
/// instead of being ignored: what a strict `init(from:)` decodes its fields from. Structured
/// setting values use it, and so do other stored values, such as a smart playlist's rules, the
/// service's replies and the device record.
public func strictContainer<Keys: CodingKey & CaseIterable>(_ decoder: any Decoder, _: Keys.Type)
    throws -> KeyedDecodingContainer<Keys>
{
    let known = Set(Keys.allCases.map(\.stringValue))
    let raw = try decoder.container(keyedBy: AnyKey.self)
    if let key = raw.allKeys.sorted(by: { $0.stringValue < $1.stringValue }).first(where: {
        !known.contains($0.stringValue)
    }) {
        throw unknownKey(key, in: raw)
    }
    return try decoder.container(keyedBy: Keys.self)
}

/// The error for `key`, which `container`'s object mustn't have: what `strictContainer` throws,
/// and a decoder that refuses one of its own keys in some uses.
public func unknownKey<Key: CodingKey>(_ key: Key, in container: KeyedDecodingContainer<Key>)
    -> DecodingError
{
    DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "unknown key")
}

private struct AnyKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
