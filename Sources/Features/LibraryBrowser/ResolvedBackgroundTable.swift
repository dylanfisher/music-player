import AppKit

/// A table that holds its background resolved for its appearance (ADR 0086). Its
/// `backgroundColor` is the resolved color; what puts the background back later, as the glass
/// does, puts back `backgroundAsSet`, which goes on following the appearance.
public protocol ResolvedBackgroundTable: NSTableView {
    var backgroundAsSet: NSColor { get }
}
