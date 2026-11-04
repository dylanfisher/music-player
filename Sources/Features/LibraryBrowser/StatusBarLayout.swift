import Settings

/// How the status bar lays out its columns (`appearance.statusBarLayout`) at the height of
/// their style: the leading columns after the scan progress, the center one centered on the
/// window, the trailing ones before the problems button. In each column the seek bar takes the
/// width its parts leave, or else the totals do, their text aligned as the column is.
public struct StatusBarLayout: Equatable, Sendable {
    /// The space above and below the art and the stacks, in points.
    static let artInsetPoints = 3.0

    public var columns: BarLayout<StatusPart>
    public var style: StatusBarStyle

    public init(columns: BarLayout<StatusPart>, style: StatusBarStyle) {
        self.columns = columns
        self.style = style
    }

    /// Whether the totals show while nothing failed.
    var showsTotals: Bool { columns.columns.contains { $0.column.parts.contains(.totals) } }

    /// The parts the column at `place` holds, in order. The center column holds the totals'
    /// label last when no column has it, shown only while it says what failed, so a failure
    /// still shows.
    func parts(at place: BarPlace) -> [StatusPart] {
        let parts = columns[place]?.parts ?? []
        return place == .center && !showsTotals ? parts + [.totals] : parts
    }

    /// The part of the column at `place` that takes the width the others leave, if it has one.
    func stretching(at place: BarPlace) -> StatusPart? {
        let parts = parts(at: place)
        return parts.contains(.seek) ? .seek : parts.contains(.totals) ? .totals : nil
    }

    /// Whether the column at `place` puts its parts one over another: only in the tall style.
    func stacks(at place: BarPlace) -> Bool { style == .tall && columns[place]?.stacks == true }

    /// The bar's height, given the track table header's, which the minimal style matches, and
    /// the tallest stacked column's, which the tall style grows to fit up to `StatusBarStyle.tallMaxPoints`.
    func heightPoints(headerPoints: Double, stackPoints: Double = 0) -> Double {
        guard style == .tall else { return headerPoints }
        let stacks = min(stackPoints + 2 * Self.artInsetPoints, StatusBarStyle.tallMaxPoints)
        return max(StatusBarStyle.tallPoints, headerPoints, stacks)
    }

    func artPoints(heightPoints: Double) -> Double { heightPoints - 2 * Self.artInsetPoints }
}
