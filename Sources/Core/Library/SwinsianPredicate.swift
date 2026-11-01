import Foundation

/// A Swinsian smart playlist's rules: an `NSPredicate` that `NSKeyedArchiver` wrote into
/// `playlist.smartpredicate` (ADR 0033). It's decoded under secure coding from the classes a
/// predicate is made of, never evaluated, and its structure is mapped onto `SmartRules`.
public enum SwinsianPredicate {
    /// The owner's largest is under 2 KB.
    static let maximumBytes = 64 << 10
    static let maximumObjects = 2048
    /// References from the root to the deepest object. `NSKeyedUnarchiver` decodes each one by
    /// recursion, and about 300 nested NOTs overflow the 512 KiB stack the import reads on.
    static let maximumDepth = 64
    /// Reasons listed for one playlist, then a count.
    public static let maximumReasons = 10
    /// Characters of a rule quoted in a reason.
    static let maximumQuotedCharacters = 200

    /// What a predicate is made of. `NSKeyedUnarchiver` also takes the private subclasses of
    /// these that the archive names, such as `NSFunctionExpression`, and nothing else.
    private static var allowedClasses: [AnyClass] {
        [
            NSPredicate.self, NSCompoundPredicate.self, NSComparisonPredicate.self,
            NSExpression.self, NSArray.self, NSString.self, NSNumber.self, NSDate.self,
        ]
    }

    /// The fields the owner's rules compare, whose Swinsian key paths are their names here;
    /// other keys don't map.
    static let fields: Set<SmartField> = [
        .genre, .fileType, .sampleRate, .bitRate, .dateAdded, .lastPlayed,
    ]
    /// Swinsian's grouping's length, which the owner's rules compare with `> 0` for "has one".
    static let groupingLength = "groupingLength"

    /// The playlist the archived predicate makes: smart when every part maps, else unmapped
    /// with each part that doesn't.
    public static func kind(_ archive: [UInt8]) -> PlayerPlaylist.Kind {
        let predicate: NSPredicate
        switch decode(archive) {
        case .success(let decoded): predicate = decoded
        case .failure(let reason): return .unmapped([reason.description])
        }
        var walk = Walk()
        let clause = walk.clause(predicate, negated: false, depth: 0)
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

    /// The archive's root predicate, after checking the archive's size and shape.
    static func decode(_ archive: [UInt8]) -> Result<NSPredicate, Unmapped> {
        guard archive.count <= maximumBytes else { return .failure(.archive(.tooLarge)) }
        let data = Data(archive)
        if let problem = shapeProblem(data) { return .failure(.archive(problem)) }
        let unarchiver: NSKeyedUnarchiver
        do {
            unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
        } catch {
            return .failure(.archive(.unreadable(error.localizedDescription)))
        }
        unarchiver.requiresSecureCoding = true
        unarchiver.decodingFailurePolicy = .setErrorAndReturn
        let root = unarchiver.decodeObject(of: allowedClasses, forKey: NSKeyedArchiveRootObjectKey)
        unarchiver.finishDecoding()
        if let error = unarchiver.error {
            return .failure(.archive(.unreadable(error.localizedDescription)))
        }
        guard let predicate = root as? NSPredicate else {
            return .failure(.archive(.unreadable("its root isn't a predicate")))
        }
        return .success(predicate)
    }

    /// Why the archive is too big or deep to decode, or nil. It's read as a property list
    /// first, so the object graph's depth is known before the unarchiver recurses through it.
    private static func shapeProblem(_ data: Data) -> Archive? {
        let plist: Any
        do {
            plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        } catch {
            return .unreadable(error.localizedDescription)
        }
        guard let top = plist as? [String: Any],
            Set(top.keys) == ["$archiver", "$objects", "$top", "$version"],
            top["$archiver"] as? String == "NSKeyedArchiver",
            let objects = top["$objects"] as? [Any], let roots = top["$top"] as? [String: Any],
            roots.count == 1, let root = roots["root"].flatMap(objectNumber)
        else { return .notAnArchive }
        guard objects.count <= maximumObjects else { return .tooManyObjects }
        // An object is a dictionary of references and values, or of arrays of them, such as
        // an array's `NS.objects`.
        let children = objects.map { object -> [Int] in
            guard let fields = object as? [String: Any] else { return [] }
            return fields.values.flatMap { value in
                (value as? [Any] ?? [value]).compactMap(objectNumber)
            }
        }
        guard root < objects.count, children.allSatisfy({ $0.allSatisfy { $0 < objects.count } })
        else { return .notAnArchive }
        // Each object's height, by a walk with its own stack, so a deep archive can't overflow
        // this one either.
        var height = [Int?](repeating: nil, count: objects.count)
        var onPath = [Bool](repeating: false, count: objects.count)
        var stack = [(object: root, next: 0)]
        onPath[root] = true
        while let (object, next) = stack.last {
            if next < children[object].count {
                stack[stack.count - 1].next += 1
                let child = children[object][next]
                if onPath[child] { return .cycle }
                if height[child] == nil {
                    onPath[child] = true
                    stack.append((child, 0))
                }
            } else {
                let own = 1 + (children[object].compactMap { height[$0] }.max() ?? 0)
                if own > maximumDepth { return .tooDeep }
                height[object] = own
                onPath[object] = false
                stack.removeLast()
            }
        }
        return nil
    }

    /// The object number a reference holds. Foundation has no API for `CFKeyedArchiverUID`'s
    /// value, so it's read from its description, `<CFKeyedArchiverUID 0x…>{value = 5}`; one of
    /// another shape is no reference, which leaves the archive refused, not misread.
    private static func objectNumber(_ value: Any) -> Int? {
        let object = value as AnyObject
        guard NSStringFromClass(type(of: object)) == "__NSCFType" else { return nil }
        let description = String(describing: object)
        guard description.hasPrefix("<CFKeyedArchiverUID "), description.hasSuffix("}"),
            let start = description.range(of: "{value = ")
        else { return nil }
        return Int(description[start.upperBound..<description.index(before: description.endIndex)])
    }

    /// Rules that all or any must hold.
    private struct Clause {
        var match: SmartRules.Match
        var rules: [SmartRule]
    }

    /// A walk over a decoded predicate, collecting why each part that doesn't map doesn't.
    private struct Walk {
        var reasons: [String] = []

        /// The rules `predicate` holds, or its negation's; nil after noting why not. A NOT is
        /// pushed down to the comparisons by De Morgan, so `NOT (a OR b)` is `NOT a AND NOT b`.
        mutating func clause(_ predicate: NSPredicate, negated: Bool, depth: Int) -> Clause? {
            guard depth <= maximumDepth else {
                reasons.append(Unmapped.archive(.tooDeep).description)
                return nil
            }
            if let compound = predicate as? NSCompoundPredicate {
                return clause(compound, negated: negated, depth: depth)
            }
            guard let comparison = predicate as? NSComparisonPredicate else {
                reasons.append(Unmapped.predicate(quoted(predicate)).description)
                return nil
            }
            switch SwinsianPredicate.rule(comparison, negated: negated) {
            case .success(let rule): return Clause(match: .all, rules: [rule])
            case .failure(let reason):
                reasons.append("\(quoted(predicate)): \(reason)")
                return nil
            }
        }

        private mutating func clause(_ compound: NSCompoundPredicate, negated: Bool, depth: Int)
            -> Clause?
        {
            let parts = compound.subpredicates.compactMap { $0 as? NSPredicate }
            guard parts.count == compound.subpredicates.count, !parts.isEmpty else {
                reasons.append(Unmapped.predicate(quoted(compound)).description)
                return nil
            }
            let match: SmartRules.Match
            switch (compound.compoundPredicateType, negated) {
            case (.not, _):
                guard parts.count == 1 else {
                    reasons.append(Unmapped.predicate(quoted(compound)).description)
                    return nil
                }
                return clause(parts[0], negated: !negated, depth: depth + 1)
            case (.and, false), (.or, true): match = .all
            case (.or, false), (.and, true): match = .any
            @unknown default:
                reasons.append(Unmapped.predicate(quoted(compound)).description)
                return nil
            }
            var rules: [SmartRule] = []
            var mapped = true
            for part in parts {
                guard let inner = clause(part, negated: negated, depth: depth + 1) else {
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

        private func quoted(_ predicate: NSPredicate) -> String {
            let format = predicate.predicateFormat
            return "“"
                + (format.count > maximumQuotedCharacters
                    ? format.prefix(maximumQuotedCharacters) + "…" : format) + "”"
        }
    }

    /// One comparison, or its negation, as a rule of ours.
    private static func rule(_ comparison: NSComparisonPredicate, negated: Bool) -> Result<
        SmartRule, Unmapped
    > {
        guard comparison.comparisonPredicateModifier == .direct,
            comparison.leftExpression.expressionType == .keyPath
        else { return .failure(.shape) }
        let key = comparison.leftExpression.keyPath
        let right = comparison.rightExpression
        let operation = comparison.predicateOperatorType
        if key == groupingLength {
            // "Longer than 0" is "isn't empty", which a text rule says.
            guard operation == .greaterThan, comparison.options.isEmpty, wholeNumber(right) == 0
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
            guard right.expressionType == .constantValue, let text = right.constantValue as? String
            else { return .failure(.value) }
            let comparisons:
                [NSComparisonPredicate.Operator: (SmartComparison, not: SmartComparison?)] = [
                    .beginsWith: (.startsWith, nil), .contains: (.contains, .doesNotContain),
                    .equalTo: (.is, .isNot),
                ]
            guard let pair = comparisons[operation] else { return .failure(.operator) }
            guard let chosen = negated ? pair.not : pair.0 else { return .failure(.negated) }
            rule = SmartRule(field, chosen, .text(text))
        case .number:
            guard comparison.options.isEmpty else { return .failure(.options) }
            guard let number = wholeNumber(right) else { return .failure(.value) }
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

    private static func wholeNumber(_ expression: NSExpression) -> Int? {
        guard expression.expressionType == .constantValue,
            let number = expression.constantValue as? NSNumber
        else { return nil }
        return Int(exactly: number.doubleValue)
    }

    /// N in `CAST(CAST(now(), "NSNumber") - N, "NSDate")`, Swinsian's "in the last N
    /// seconds"; nil for any other expression, such as a fixed date.
    private static func secondsBeforeNow(_ expression: NSExpression) -> Double? {
        guard let cast = call(expression, "castObject:toType:", count: 2),
            constant(cast[1]) as? String == "NSDate",
            let difference = call(cast[0], "from:subtract:", count: 2),
            let seconds = constant(difference[1]) as? NSNumber,
            let now = call(difference[0], "castObject:toType:", count: 2),
            constant(now[1]) as? String == "NSNumber", call(now[0], "now", count: 0) != nil
        else { return nil }
        return seconds.doubleValue.isFinite ? seconds.doubleValue : nil
    }

    /// The arguments of a call to `function` with `count` of them, or nil.
    private static func call(_ expression: NSExpression, _ function: String, count: Int)
        -> [NSExpression]?
    {
        guard expression.expressionType == .function, expression.function == function else {
            return nil
        }
        let arguments = expression.arguments ?? []
        return arguments.count == count ? arguments : nil
    }

    private static func constant(_ expression: NSExpression) -> Any? {
        expression.expressionType == .constantValue ? expression.constantValue : nil
    }

    /// Why an archive can't be decoded.
    enum Archive: Equatable, CustomStringConvertible {
        case tooLarge, notAnArchive, tooManyObjects, tooDeep, cycle
        case unreadable(String)

        var description: String {
            switch self {
            case .tooLarge: "its rules are over \(maximumBytes) bytes"
            case .notAnArchive: "its rules aren't an archive Swinsian writes"
            case .tooManyObjects: "its rules are over \(maximumObjects) objects"
            case .tooDeep: "its rules nest deeper than \(maximumDepth)"
            case .cycle: "its rules refer to themselves"
            case .unreadable(let detail): "its rules couldn't be read: \(detail)"
            }
        }
    }

    /// Why a predicate, or a part of one, doesn't map.
    enum Unmapped: Error, Equatable, CustomStringConvertible {
        case archive(Archive)
        case predicate(String)
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
            case .archive(let archive): archive.description
            case .predicate(let quoted): "\(quoted) isn't a comparison or AND, OR or NOT"
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
