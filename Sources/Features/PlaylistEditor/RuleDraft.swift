import Library

/// A smart playlist as the rule editor holds it while it's being edited: the name, the rows of
/// field, comparison and typed value, all or any, and the limit. Typed text stays as typed until
/// `rules()` reads it, so a half-typed number isn't lost or refused mid-edit.
public struct RuleDraft: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        public var field: SmartField
        public var comparison: SmartComparison
        public var value: String
    }

    /// Why the draft can't be saved yet, as the sheet shows it.
    public struct Problem: Error, Equatable, CustomStringConvertible {
        public var description: String
    }

    public var name: String
    public var match: SmartRules.Match
    public private(set) var rows: [Row]
    public var isLimited: Bool
    public var limitCount: String
    public var limitOrder: SmartOrder

    /// The count a limit starts at when it's turned on.
    public static let defaultLimit = 25

    /// Starts from `rules`, or from one empty rule for a new playlist.
    public init(name: String, rules: SmartRules?) {
        self.name = name
        match = rules?.match ?? .all
        rows = (rules?.rules ?? []).map { rule in
            let value: String =
                switch rule.value {
                case .text(let text): text
                case .number(let number): String(number)
                }
            return Row(field: rule.field, comparison: rule.comparison, value: value)
        }
        if rows.isEmpty { rows = [Self.newRow] }
        isLimited = rules?.limit != nil
        limitCount = String(rules?.limit?.count ?? Self.defaultLimit)
        limitOrder = rules?.limit?.order ?? .mostPlayed
    }

    private static let newRow = Row(field: .title, comparison: .contains, value: "")

    /// Adds an empty rule after row `index`.
    public mutating func addRow(after index: Int) {
        rows.insert(Self.newRow, at: min(index + 1, rows.count))
    }

    /// Removes row `index`. The last row stays, since a rule editor with none has nothing to
    /// add to; an empty title rule matches every track.
    public mutating func removeRow(at index: Int) {
        guard rows.count > 1, rows.indices.contains(index) else { return }
        rows.remove(at: index)
    }

    /// Sets a row's field. A comparison the new field can't take becomes its first one, and a
    /// value of the other kind is cleared.
    public mutating func setField(_ field: SmartField, at index: Int) {
        let comparisons = SmartComparison.comparisons(for: field.kind)
        if !comparisons.contains(rows[index].comparison) {
            rows[index].comparison = comparisons[0]
        }
        if (field.kind == .text) != (rows[index].field.kind == .text) { rows[index].value = "" }
        rows[index].field = field
    }

    public mutating func setComparison(_ comparison: SmartComparison, at index: Int) {
        precondition(
            SmartComparison.comparisons(for: rows[index].field.kind).contains(comparison),
            "\(comparison) for \(rows[index].field)")
        rows[index].comparison = comparison
    }

    public mutating func setValue(_ value: String, at index: Int) {
        rows[index].value = value
    }

    /// The trimmed name, or a problem when it's empty.
    public func checkedName() throws(Problem) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Problem(description: "Give the playlist a name.") }
        return trimmed
    }

    /// The rules as typed, or the first problem with them.
    public func rules() throws(Problem) -> SmartRules {
        var rules: [SmartRule] = []
        for (index, row) in rows.enumerated() {
            let value: SmartValue
            if row.field.kind == .text {
                value = .text(row.value)
            } else {
                guard let number = Int(row.value.trimmingCharacters(in: .whitespaces)) else {
                    throw Problem(description: "Rule \(index + 1) needs a whole number.")
                }
                value = .number(number)
            }
            let rule = SmartRule(row.field, row.comparison, value)
            if let problem = rule.problem {
                throw Problem(description: "Rule \(index + 1): \(problem).")
            }
            rules.append(rule)
        }
        var limit: SmartLimit?
        if isLimited {
            guard let count = Int(limitCount.trimmingCharacters(in: .whitespaces)), count > 0
            else { throw Problem(description: "The limit needs a number of tracks above 0.") }
            limit = SmartLimit(count: count, order: limitOrder)
        }
        return SmartRules(match: match, rules: rules, limit: limit)
    }
}
