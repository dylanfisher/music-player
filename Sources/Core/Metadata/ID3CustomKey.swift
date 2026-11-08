/// The custom keys ID3 holds in frames other than `TXXX` (ADR 0129): `WXXX` links, where YATE
/// writes the Discogs URLs, and the involved people list, where it writes the credits
/// (ADR 0128). They are named apart from a `TXXX` of the same description, since a tag can hold
/// both, and no other format has them.
public enum ID3CustomKey {
    /// The custom key a `WXXX` frame described `description` reads as, and writes.
    public static func url(_ description: String) -> String { urlPrefix + description }

    /// The custom key of the involved people list: `TIPL`, or `IPLS` in ID3v2.3.
    public static let involvedPeople = id3InvolvedPeopleFrameID(version: 4)

    /// What the involved people list's roles and names are joined with as one value: YATE's
    /// separator between values.
    public static let involvedPeopleSeparator = ";;;"

    /// Whether `name` is one of these keys, compared uppercased, which only ID3 can hold.
    public static func isID3Only(_ name: String) -> Bool {
        let upper = name.uppercased()
        return upper.hasPrefix(urlPrefix) || upper == involvedPeople
    }

    /// The description of the `WXXX` frame `name` writes, as spelled; nil for any other key.
    package static func urlDescription(_ name: String) -> String? {
        name.uppercased().hasPrefix(urlPrefix) ? String(name.dropFirst(urlPrefix.count)) : nil
    }

    private static let urlPrefix = id3UserURLFrameID + ":"
}
