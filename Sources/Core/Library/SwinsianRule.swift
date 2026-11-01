/// One row of Swinsian's `smartrule` table, as the assumed schema reads it (ADR 0033).
struct SwinsianRule: Equatable, Sendable {
    var field: Cell
    var `operator`: Cell
    var value: Cell

    /// Swinsian's names for fields and comparisons are assumed to be ours, ignoring case
    /// (ADR 0033); one that isn't doesn't map.
    static let fields = Dictionary(
        uniqueKeysWithValues: SmartField.allCases.map { ($0.rawValue.lowercased(), $0) })
    static let comparisons = Dictionary(
        uniqueKeysWithValues: SmartComparison.allCases.map { ($0.rawValue.lowercased(), $0) })

    /// The rule as ours, or why it can't be one.
    func smartRule() -> Result<SmartRule, Unmapped> {
        guard case .text(let fieldName) = field else { return .failure(.notText("field")) }
        guard case .text(let operatorName) = `operator` else {
            return .failure(.notText("operator"))
        }
        guard let smartField = Self.fields[fieldName.lowercased()] else {
            return .failure(.field(fieldName))
        }
        guard let comparison = Self.comparisons[operatorName.lowercased()] else {
            return .failure(.operator(operatorName))
        }
        if case .longText = value { return .failure(.invalid(SmartRule.textTooLong)) }
        let smartValue: SmartValue
        switch (smartField.kind, value) {
        case (.text, .text(let text)): smartValue = .text(text)
        case (.text, .integer(let number)): smartValue = .text(String(number))
        case (.number, .integer(let number)), (.date, .integer(let number)):
            guard let number = Int(exactly: number) else { return .failure(.value(fieldName)) }
            smartValue = .number(number)
        case (.number, .text(let text)), (.date, .text(let text)):
            guard let number = Int(text) else { return .failure(.value(fieldName)) }
            smartValue = .number(number)
        default: return .failure(.value(fieldName))
        }
        let rule = SmartRule(smartField, comparison, smartValue)
        if let problem = rule.problem { return .failure(.invalid(problem)) }
        return .success(rule)
    }

    /// Why a rule doesn't map.
    enum Unmapped: Error, Equatable, CustomStringConvertible {
        case notText(String)
        case field(String)
        case `operator`(String)
        case value(String)
        case invalid(String)

        var description: String {
            switch self {
            case .notText(let column): "a rule's \(column) isn't text"
            case .field(let name): "the field “\(name)” has no match here"
            case .operator(let name): "the comparison “\(name)” has no match here"
            case .value(let field): "the value for “\(field)” isn't what the field takes"
            case .invalid(let problem): problem
            }
        }
    }
}
