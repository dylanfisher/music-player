/// A part the toolbar's now-playing status can show, as the user arranges them in its builder:
/// the playing track's art, its title, its artist and album, its format and a seek bar.
public enum HeaderPart: String, BarPart {
    case art, title, subtitle, format, seek

    /// The art's size in points.
    public static let artPoints = 48

    public var title: String {
        switch self {
        case .art: StatusPart.art.title
        case .title: "Title"
        case .subtitle: "Artist and Album"
        case .format: StatusPart.format.title
        case .seek: StatusPart.seek.title
        }
    }

    /// The art is a square as tall as the status's text, so it doesn't stack with it.
    public var fillsHeight: Bool { self == .art }
}

extension BarLayout where Part == HeaderPart {
    /// The art, and beside it the title, the artist and album and the format over the seek bar,
    /// across the rest of the status.
    public static let defaultHeaderStatus = BarLayout(
        leading: [
            BarColumn(parts: [.art], width: .fixed(HeaderPart.artPoints), alignment: .leading)
        ],
        center: BarColumn(
            parts: [.title, .subtitle, .format, .seek], width: .flexible, alignment: .leading,
            stacks: true))
}
