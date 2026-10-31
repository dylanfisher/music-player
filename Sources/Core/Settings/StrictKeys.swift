/// Throws when the object being decoded has a key outside `Keys`, so a misspelled field fails
/// instead of being ignored. Structured setting values call it first in `init(from:)`.
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

private struct AnyKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
