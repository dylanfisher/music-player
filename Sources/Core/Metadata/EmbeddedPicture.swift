/// One picture a file embeds, and what the file says it shows.
public struct EmbeddedPicture: Equatable, Sendable {
    public var art: EmbeddedArt
    /// The picture type FLAC PICTURE and ID3 APIC share, 3 for the front cover; nil in MP4,
    /// whose `covr` gives none.
    var type: UInt32?

    /// What the picture shows: the front and back covers, a leaflet page and the disc's label
    /// by name, and every other ID3 and FLAC type as Other; nil when the file doesn't say.
    public var typeName: String? {
        switch type {
        case nil: nil
        case 3: "Front Cover"
        case 4: "Back Cover"
        case 5: "Leaflet Page"
        case 6: "Disc Label"
        default: "Other"
        }
    }
}

/// The front cover (picture type 3) if there is one, otherwise the first picture: the one
/// `TrackMetadata.art` holds.
func preferredPicture(_ pictures: [EmbeddedPicture]) -> EmbeddedArt? {
    (pictures.first { $0.type == 3 } ?? pictures.first)?.art
}
