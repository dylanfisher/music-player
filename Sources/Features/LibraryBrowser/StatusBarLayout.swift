import Settings

/// How the status bar lays out the parts the user chose (`appearance.statusBarParts`) at the
/// height of their style: left to right in their order, between the scan progress and the
/// problems button, with the seek bar taking the free width, or else the totals, centered in it.
public struct StatusBarLayout: Equatable, Sendable {
    /// The tall style's height, in points: two lines of text and art beside them.
    static let tallPoints = 44.0
    /// The space above and below the art, in points.
    static let artInsetPoints = 3.0

    public var parts: [StatusPart]
    public var style: StatusBarStyle

    public init(parts: [StatusPart], style: StatusBarStyle) {
        self.parts = parts
        self.style = style
    }

    /// The parts in the order the bar holds them. The totals' label comes last when not chosen,
    /// shown only while it says what failed, so a failure still shows.
    var order: [StatusPart] { parts.contains(.totals) ? parts : parts + [.totals] }

    /// Whether the totals show while nothing failed.
    var showsTotals: Bool { parts.contains(.totals) }

    /// The part that takes the width the others leave.
    var flexible: StatusPart { parts.contains(.seek) ? .seek : .totals }

    /// The bar's height, given the track table header's, which the minimal style matches.
    func heightPoints(headerPoints: Double) -> Double {
        style == .tall ? max(Self.tallPoints, headerPoints) : headerPoints
    }

    func artPoints(headerPoints: Double) -> Double {
        heightPoints(headerPoints: headerPoints) - 2 * Self.artInsetPoints
    }
}
