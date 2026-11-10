/// One picture a file embeds, and what the file says it shows.
public struct EmbeddedPicture: Equatable, Sendable {
    public var art: EmbeddedArt
    /// The picture type FLAC PICTURE and ID3 APIC share; nil in MP4, whose `covr` gives none.
    public var type: PictureType?

    /// What the picture shows, as `PictureType.name` says; nil when the file doesn't say.
    public var typeName: String? { type?.name }
}

/// The number ID3 APIC and FLAC PICTURE give what a picture shows, 3 for the front cover. A
/// number a file holds is kept as it is; the editor offers `choices`.
public struct PictureType: RawRepresentable, Hashable, Sendable, ExpressibleByIntegerLiteral {
    public var rawValue: UInt32

    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(integerLiteral value: UInt32) { self.init(rawValue: value) }

    public static let other: PictureType = 0
    public static let frontCover: PictureType = 3
    public static let backCover: PictureType = 4
    public static let leafletPage: PictureType = 5
    public static let discLabel: PictureType = 6

    /// The types a picture can be given, in the order a menu lists them.
    public static let choices: [PictureType] = [
        .frontCover, .backCover, .leafletPage, .discLabel, .other,
    ]

    /// The front and back covers, a leaflet page and the disc's label by name, and every other
    /// type as Other.
    public var name: String {
        switch self {
        case .frontCover: "Front Cover"
        case .backCover: "Back Cover"
        case .leafletPage: "Leaflet Page"
        case .discLabel: "Disc Label"
        default: "Other"
        }
    }
}

/// The front cover if there is one, otherwise the first picture: the one `TrackMetadata.art`
/// holds.
func preferredPicture(_ pictures: [EmbeddedPicture]) -> EmbeddedArt? {
    (pictures.first { $0.type == .frontCover } ?? pictures.first)?.art
}

extension Array where Element == EmbeddedPicture {
    /// The pictures with the one `preferredPicture` picks first, the rest in file order: the
    /// order the art viewer steps through, so it opens on 1 of N with the art the rows show.
    public var frontFirst: [EmbeddedPicture] {
        guard let front = preferredPicture(self), let index = firstIndex(where: { $0.art == front })
        else { return self }
        var ordered = self
        ordered.insert(ordered.remove(at: index), at: 0)
        return ordered
    }
}
