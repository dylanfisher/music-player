import Foundation

/// A Swinsian smart playlist's rules, an `NSPredicate` that `NSKeyedArchiver` wrote into
/// `playlist.smartpredicate` (ADR 0033), mapped onto `SmartRules`. The archive is read by
/// `SwinsianArchive`, never decoded into a predicate or evaluated.
public enum SwinsianPredicate {
    /// Reasons listed for one playlist, then a count.
    public static let maximumReasons = 10
    /// Characters of a rule quoted in a reason.
    static let maximumQuotedCharacters = 200

    /// The fields the owner's rules compare, whose Swinsian key paths are their names here;
    /// other keys don't map.
    static let fields: Set<SmartField> = [
        .genre, .fileType, .sampleRate, .bitRate, .dateAdded, .lastPlayed,
    ]
    /// Swinsian's grouping's length, which the owner's rules compare with `> 0` for "has one".
    static let groupingLength = "groupingLength"
    /// Swinsian's file type names that aren't our file type, the extension: DSDIFF files are
    /// `.dff` (ADR 0033).
    static let fileTypes = ["dsd": "dff"]

    /// The playlist the archived predicate makes: smart when every part maps, else unmapped
    /// with each part that doesn't.
    public static func kind(_ archive: [UInt8]) -> PlayerPlaylist.Kind {
        let rule: SwinsianRule
        switch SwinsianArchive.rule(archive) {
        case .success(let read): rule = read
        case .failure(let problem): return .unmapped([problem.description])
        }
        var walk = Walk()
        let clause = walk.clause(rule, negated: false)
        guard let clause, walk.reasons.isEmpty else {
            var reasons = Array(walk.reasons.prefix(maximumReasons))
            if walk.reasons.count > maximumReasons {
                reasons.append("\(walk.reasons.count - maximumReasons) more")
            }
            return .unmapped(reasons)
        }
        guard clause.rules.count <= PlayerLibrary.maximumRules else {
            return .unmapped([Unmapped.tooManyRules.description])
        }
        return .smart(SmartRules(match: clause.match, rules: clause.rules))
    }

    /// Rules that all or any must hold.
    private struct Clause {
        var match: SmartRules.Match
        var rules: [SmartRule]
    }

    /// A walk over a read predicate, collecting why each part that doesn't map doesn't. The
    /// archive's depth is capped, so its recursion is too.
    private struct Walk {
        var reasons: [String] = []

        /// The rules `rule` holds, or its negation's; nil after noting why not. A NOT is pushed
        /// down to the comparisons by De Morgan, so `NOT (a OR b)` is `NOT a AND NOT b`.
        mutating func clause(_ rule: SwinsianRule, negated: Bool) -> Clause? {
            switch rule {
            case .compound(let type, let parts):
                return clause(type, parts, rule, negated: negated)
            case .comparison(let comparison):
                switch SwinsianPredicate.rule(comparison, negated: negated) {
                case .success(let mapped): return Clause(match: .all, rules: [mapped])
                case .failure(let reason):
                    reasons.append("\(quoted(rule)): \(reason)")
                    return nil
                }
            case .unsupported:
                reasons.append(Unmapped.unsupported(quoted(rule)).description)
                return nil
            }
        }

        private mutating func clause(
            _ type: NSCompoundPredicate.LogicalType, _ parts: [SwinsianRule],
            _ rule: SwinsianRule, negated: Bool
        ) -> Clause? {
            if type == .not, parts.count == 1 { return clause(parts[0], negated: !negated) }
            let match: SmartRules.Match? =
                switch (type, negated) {
                case (.and, false), (.or, true): .all
                case (.or, false), (.and, true): .any
                default: nil
                }
            guard let match, !parts.isEmpty else {
                reasons.append(Unmapped.unsupported(quoted(rule)).description)
                return nil
            }
            var rules: [SmartRule] = []
            var mapped = true
            for part in parts {
                guard let inner = clause(part, negated: negated) else {
                    mapped = false
                    continue
                }
                // One rule holds alike under all and any.
                guard inner.match == match || inner.rules.count == 1 else {
                    reasons.append("\(quoted(part)): \(Unmapped.mixed)")
                    mapped = false
                    continue
                }
                rules += inner.rules
            }
            return mapped ? Clause(match: match, rules: rules) : nil
        }

        private func quoted(_ rule: SwinsianRule) -> String {
            "“\(rule.quoted(limit: maximumQuotedCharacters))”"
        }
    }

    /// One comparison, or its negation, as a rule of ours.
    private static func rule(_ comparison: SwinsianComparison, negated: Bool) -> Result<
        SmartRule, Unmapped
    > {
        guard comparison.modifier == NSComparisonPredicate.Modifier.direct.rawValue,
            case .keyPath(let key) = comparison.left
        else { return .failure(.shape) }
        guard let operation = comparison.operation else { return .failure(.operator) }
        let right = comparison.right
        if key == groupingLength {
            // "Longer than 0" is "isn't empty", which a text rule says.
            guard operation == .greaterThan, comparison.options.isEmpty, right == .number(0)
            else { return .failure(.groupingLength) }
            return .success(SmartRule(.grouping, negated ? .is : .isNot, .text("")))
        }
        guard let field = SmartField(rawValue: key), fields.contains(field) else {
            return .failure(.key(key))
        }
        let rule: SmartRule
        switch field.kind {
        case .text:
            // Ours compare ignoring case, so only Swinsian's `[c]` comparisons match the same.
            guard comparison.options == .caseInsensitive else { return .failure(.options) }
            if case .longText = right { return .failure(.invalid(SmartRule.textTooLong)) }
            guard case .text(let text) = right else { return .failure(.value) }
            let comparisons:
                [NSComparisonPredicate.Operator: (SmartComparison, not: SmartComparison?)] = [
                    .beginsWith: (.startsWith, nil), .contains: (.contains, .doesNotContain),
                    .equalTo: (.is, .isNot),
                ]
            guard let pair = comparisons[operation] else { return .failure(.operator) }
            guard let chosen = negated ? pair.not : pair.0 else { return .failure(.negated) }
            let value = field == .fileType ? fileTypes[text.lowercased()] ?? text : text
            rule = SmartRule(field, chosen, .text(value))
        case .number:
            guard comparison.options.isEmpty else { return .failure(.options) }
            guard case .number(let real) = right, let number = Int(exactly: real) else {
                return .failure(.value)
            }
            let comparisons:
                [NSComparisonPredicate.Operator: (SmartComparison, not: SmartComparison?)] = [
                    .greaterThan: (.greaterThan, nil), .equalTo: (.is, .isNot),
                ]
            guard let pair = comparisons[operation] else { return .failure(.operator) }
            guard let chosen = negated ? pair.not : pair.0 else { return .failure(.negated) }
            rule = SmartRule(field, chosen, .number(number))
        case .date:
            guard operation == .greaterThan, comparison.options.isEmpty else {
                return .failure(.operator)
            }
            guard let seconds = secondsBeforeNow(right) else { return .failure(.absoluteDate) }
            guard seconds > 0, seconds.truncatingRemainder(dividingBy: secondsPerDay) == 0,
                let days = Int(exactly: seconds / secondsPerDay)
            else { return .failure(.notWholeDays) }
            rule = SmartRule(field, negated ? .notInLast : .inLast, .number(days))
        }
        if let problem = rule.problem { return .failure(.invalid(problem)) }
        return .success(rule)
    }

    private static let secondsPerDay = 86_400.0

    /// N in `CAST(CAST(now(), "NSNumber") - N, "NSDate")`, Swinsian's "in the last N
    /// seconds"; nil for any other expression, such as a fixed date.
    private static func secondsBeforeNow(_ expression: SwinsianExpression) -> Double? {
        guard case .function(SwinsianExpression.cast, let cast) = expression, cast.count == 2,
            cast[1] == .text("NSDate"),
            case .function(SwinsianExpression.subtract, let difference) = cast[0],
            difference.count == 2,
            case .number(let seconds) = difference[1],
            case .function(SwinsianExpression.cast, let now) = difference[0], now.count == 2,
            now[1] == .text("NSNumber"), now[0] == .function("now", [])
        else { return nil }
        return seconds
    }

    /// Why a predicate, or a part of one, doesn't map.
    enum Unmapped: Error, Equatable, CustomStringConvertible {
        case unsupported(String)
        case mixed
        case shape
        case key(String)
        case groupingLength
        case options
        case `operator`
        case negated
        case value
        case absoluteDate
        case notWholeDays
        case tooManyRules
        case invalid(String)

        var description: String {
            switch self {
            case .unsupported(let quoted): "\(quoted) is an unsupported rule"
            case .mixed: "all and any mixed in one playlist"
            case .shape: "not a key compared with a value"
            case .key(let key): "the field “\(key)” has no match here"
            case .groupingLength: "only a grouping longer than 0 has a match here"
            case .options: "compares with case or other options that have no match here"
            case .operator: "the comparison has no match here"
            case .negated: "the comparison's negation has no match here"
            case .value: "the value isn't what the field takes"
            case .absoluteDate: "only a date within the last so many days has a match here"
            case .notWholeDays: "the time isn't a whole number of days"
            case .tooManyRules: "more than \(PlayerLibrary.maximumRules) rules"
            case .invalid(let problem): problem
            }
        }
    }
}
