/// How the user left a table's columns: their widths in points and their order, by column
/// name, and the column it sorts by. A column the table no longer has is ignored when it opens,
/// and one not listed keeps its own width and place after those that are.
public struct TableLayout: Codable, Equatable, Sendable {
    public var widths: [String: Double]
    /// The columns' names left to right.
    public var order: [String]
    /// Nil for a table that doesn't sort, or wasn't sorted.
    public var sortColumn: String?
    public var sortAscending: Bool

    public init(
        widths: [String: Double], order: [String], sortColumn: String?, sortAscending: Bool
    ) {
        self.widths = widths
        self.order = order
        self.sortColumn = sortColumn
        self.sortAscending = sortAscending
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case widths, order, sortColumn, sortAscending
    }

    public init(from decoder: any Decoder) throws {
        let container = try strictContainer(decoder, CodingKeys.self)
        widths = try container.decode([String: Double].self, forKey: .widths)
        order = try container.decode([String].self, forKey: .order)
        sortColumn = try container.decodeIfPresent(String.self, forKey: .sortColumn)
        sortAscending = try container.decode(Bool.self, forKey: .sortAscending)
    }

    /// What's wrong with the layout, or nil.
    func problem() -> String? {
        if widths.values.contains(where: { !($0 > 0) }) { return "a column's width isn't positive" }
        if Set(order).count != order.count { return "a column is named twice in the order" }
        return nil
    }
}
