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
        throw DecodingError.dataCorruptedError(
            forKey: key, in: raw, debugDescription: "unknown key")
    }
    return try decoder.container(keyedBy: Keys.self)
}

private struct AnyKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
