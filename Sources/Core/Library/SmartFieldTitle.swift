extension SmartField {
    /// As the field's pop-up button lists it: the column's header, except where that's too
    /// short to read in a menu.
    public var title: String {
        switch self {
        case .composer: "Composer"
        case .comment: "Comment"
        case .trackNumber: "Track Number"
        case .discNumber: "Disc Number"
        case .bitDepth: "Bit Depth"
        default: column!.title
        }
    }
}
