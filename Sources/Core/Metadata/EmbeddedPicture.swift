/// One picture a file embeds, and what the file says it shows.
public struct EmbeddedPicture: Equatable, Sendable {
    public var art: EmbeddedArt
    /// The picture type FLAC PICTURE and ID3 APIC share, 3 for the front cover; nil in MP4,
    /// whose `covr` gives none.
    var type: UInt32?

    /// What the picture shows, as the ID3 and FLAC specifications name its type; nil when the
    /// file doesn't say.
    public var typeName: String? {
        guard let type else { return nil }
        return Self.typeNames.indices.contains(Int(type)) ? Self.typeNames[Int(type)] : "Other"
    }

    private static let typeNames = [
        "Other", "File Icon", "Other File Icon", "Front Cover", "Back Cover", "Leaflet Page",
        "Media", "Lead Artist", "Artist", "Conductor", "Band", "Composer", "Lyricist",
        "Recording Location", "During Recording", "During Performance", "Video Capture",
        "Bright Colored Fish", "Illustration", "Band Logo", "Publisher Logo",
    ]
}

/// The front cover (picture type 3) if there is one, otherwise the first picture: the one
/// `TrackMetadata.art` holds.
func preferredPicture(_ pictures: [EmbeddedPicture]) -> EmbeddedArt? {
    (pictures.first { $0.type == 3 } ?? pictures.first)?.art
}
