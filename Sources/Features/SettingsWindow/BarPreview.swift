import Foundation
import Settings

/// Where the bar builder's preview draws each column across a bar `width` wide, by the bar's
/// rules: fixed columns at their width, flexible ones sharing what's left equally but never
/// narrower than their parts, the leading columns from the left, the trailing ones from the
/// right, the center column on the bar's center line unless that would overlap a side, and
/// flexible side columns reaching to it (ADR 0085). It approximates the bar's constraints with
/// arithmetic; the bar itself changes as each edit saves.
struct BarPreview {
    typealias Span = (x: Double, width: Double)

    var spacing: Double
    var inset: Double

    /// Each column's left edge and width, by place. `natural` is how wide a column's parts are.
    func columns(
        of layout: BarLayout<String>, width: Double, natural: (BarPlace) -> Double
    ) -> [BarPlace: Span] {
        let columns = layout.columns
        var fixedPoints = 0.0
        for (_, column) in columns {
            if case .fixed(let points) = column.width { fixedPoints += Double(points) }
        }
        let flexibleCount = columns.filter { $0.column.width == .flexible }.count
        let room = width - 2 * inset - Double(columns.count + 1) * spacing - fixedPoints
        let share = flexibleCount > 0 ? max(room / Double(flexibleCount), 0) : 0
        // Side columns at their parts' width until they reach to the center below; the center
        // at its share.
        var widths: [BarPlace: Double] = [:]
        for (place, column) in columns {
            widths[place] =
                switch column.width {
                case .fixed(let points): Double(points)
                case .flexible: place == .center ? max(share, natural(place)) : natural(place)
                }
        }
        let centerWidth = widths[.center] ?? 0
        let leading = layout.leading.indices.map(BarPlace.leading)
        let trailing = layout.trailing.indices.map(BarPlace.trailing)
        let leadingEnd = inset + sum(leading, widths) + spacing
        let trailingStart = width - inset - sum(trailing, widths) - spacing
        let centerX = min(max((width - centerWidth) / 2, leadingEnd), trailingStart - centerWidth)
        // A side with a flexible column reaches to the center.
        for (places, side, room) in [
            (leading, layout.leading, centerX - spacing - inset),
            (trailing, layout.trailing, width - inset - centerX - centerWidth - spacing),
        ] {
            let flexible = side.filter { $0.width == .flexible }.count
            let extra = (room - sum(places, widths)) / Double(max(flexible, 1))
            guard flexible > 0, extra > 0 else { continue }
            for (place, column) in zip(places, side) where column.width == .flexible {
                widths[place, default: 0] += extra
            }
        }
        var spans: [BarPlace: Span] = [.center: (centerX, centerWidth)]
        var x = inset
        for place in leading {
            spans[place] = (x, widths[place] ?? 0)
            x += (widths[place] ?? 0) + spacing
        }
        x = width - inset
        for place in trailing.reversed() {
            x -= widths[place] ?? 0
            spans[place] = (x, widths[place] ?? 0)
            x -= spacing
        }
        return spans
    }

    /// The width of the columns at `places` with the spacing between them.
    private func sum(_ places: [BarPlace], _ widths: [BarPlace: Double]) -> Double {
        guard !places.isEmpty else { return 0 }
        return places.compactMap { widths[$0] }.reduce(0, +) + Double(places.count - 1) * spacing
    }
}
