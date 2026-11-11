/// Throws when the object being decoded has a key outside `Keys`, so a misspelled field fails
/// instead of being ignored. Structured setting values call it first in `init(from:)`, and so do
/// other stored values, such as a smart playlist's rules.
func rejectUnknownKeys<Keys: CodingKey & CaseIterable>(_ decoder: any Decoder, _: Keys.Type)
    throws
{
    let known = Set(Keys.allCases.map(\.stringValue))
    let raw = try decoder.container(keyedBy: AnyKey.self)
    if let key = raw.allKeys.sorted(by: { $0.stringValue < $1.stringValue }).first(where: {
        !known.contains($0.stringValue)
    }) {
        throw DecodingError.dataCorruptedError(
            forKey: key, in: raw, debugDescription: "unknown key")
    }
}

/// `decoder`'s object, checked by `rejectUnknownKeys` to have no key outside `Keys`: what a
/// strict `init(from:)` decodes its fields from.
public func strictContainer<Keys: CodingKey & CaseIterable>(_ decoder: any Decoder, _: Keys.Type)
    throws -> KeyedDecodingContainer<Keys>
{
    try rejectUnknownKeys(decoder, Keys.self)
    return try decoder.container(keyedBy: Keys.self)
}

private struct AnyKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
