import Foundation

/// A Swinsian smart playlist's predicate as its `NSKeyedArchiver` archive describes it, read
/// from the archive's property list without `NSKeyedUnarchiver` (ADR 0033): `NSPredicate`
/// raises an Objective-C exception, which Swift can't catch, for a malformed archive. Only the
/// parts the import maps are read; any other part is `unsupported`.
indirect enum SwinsianRule: Equatable, Sendable {
    case compound(NSCompoundPredicate.LogicalType, [SwinsianRule])
    case comparison(SwinsianComparison)
    /// A part the import doesn't read, by its class name.
    case unsupported(String)

    /// The rule in `NSPredicate`'s format, cut at `limit` characters with "…". It's written
    /// only up to the limit, since a rule can list one part many times.
    func quoted(limit: Int) -> String {
        var text = CappedText(limit: limit)
        write(to: &text)
        return text.text + (text.isCut ? "…" : "")
    }

    fileprivate func write(to text: inout CappedText) {
        switch self {
        case .compound(.not, let parts) where parts.count == 1:
            text.append("NOT ")
            parts[0].writeGrouped(to: &text)
        case .compound(let type, let parts):
            for (index, part) in parts.enumerated() {
                if text.isCut { return }
                if index > 0 { text.append(type == .or ? " OR " : " AND ") }
                part.writeGrouped(to: &text)
            }
        case .comparison(let comparison): comparison.write(to: &text)
        case .unsupported(let name): text.append(name)
        }
    }

    private func writeGrouped(to text: inout CappedText) {
        guard case .compound = self else { return write(to: &text) }
        text.append("(")
        write(to: &text)
        text.append(")")
    }
}

/// Text written up to `limit` characters; past it, appends are dropped.
struct CappedText {
    let limit: Int
    private(set) var text = ""
    private(set) var count = 0
    /// Whether something was dropped.
    private(set) var isCut = false

    init(limit: Int) { self.limit = limit }

    mutating func append(_ piece: String) {
        guard !isCut else { return }
        let head = piece.prefix(limit - count + 1)
        if head.count <= limit - count {
            text += head
            count += head.count
        } else {
            text += head.dropLast()
            count = limit
            isCut = true
        }
    }
}

struct SwinsianComparison: Equatable, Sendable {
    var left: SwinsianExpression
    var operatorType: UInt
    var options: NSComparisonPredicate.Options
    var modifier: UInt
    var right: SwinsianExpression

    var operation: NSComparisonPredicate.Operator? { .init(rawValue: operatorType) }

    fileprivate func write(to text: inout CappedText) {
        let name = operation.flatMap { Self.names[$0] } ?? "operator \(operatorType)"
        let flags = zip("cdn", [.caseInsensitive, .diacriticInsensitive, .normalized]).compactMap {
            options.contains($1) ? $0 : nil
        }
        text.append([1: "ALL ", 2: "ANY "][modifier] ?? "")
        left.write(to: &text)
        text.append(" \(name)\(flags.isEmpty ? "" : "[\(String(flags))]") ")
        right.write(to: &text)
    }

    private static let names: [NSComparisonPredicate.Operator: String] = [
        .lessThan: "<", .lessThanOrEqualTo: "<=", .greaterThan: ">", .greaterThanOrEqualTo: ">=",
        .equalTo: "==", .notEqualTo: "!=", .matches: "MATCHES", .like: "LIKE",
        .beginsWith: "BEGINSWITH", .endsWith: "ENDSWITH", .in: "IN", .contains: "CONTAINS",
        .between: "BETWEEN",
    ]
}

indirect enum SwinsianExpression: Equatable, Sendable {
    /// The selectors of `CAST(a, b)` and `a - b`.
    static let cast = "castObject:toType:"
    static let subtract = "from:subtract:"

    case keyPath(String)
    case text(String)
    /// Text over `SwinsianArchive.maximumTextBytes`, by its byte count.
    case longText(Int)
    case number(Double)
    case function(String, [SwinsianExpression])
    case unsupported(String)

    fileprivate func write(to text: inout CappedText) {
        switch self {
        case .keyPath(let path): text.append(path)
        case .text(let string): text.append("\"\(string)\"")
        case .longText(let bytes): text.append("<text of \(bytes) bytes>")
        case .number(let number): text.append(Int(exactly: number).map(String.init) ?? "\(number)")
        case .function(SwinsianExpression.cast, let arguments) where arguments.count == 2:
            text.append("CAST(")
            arguments[0].write(to: &text)
            text.append(", ")
            arguments[1].write(to: &text)
            text.append(")")
        case .function(SwinsianExpression.subtract, let arguments) where arguments.count == 2:
            arguments[0].write(to: &text)
            text.append(" - ")
            arguments[1].write(to: &text)
        case .function(let name, let arguments):
            text.append("\(name)(")
            for (index, argument) in arguments.enumerated() {
                if text.isCut { return }
                if index > 0 { text.append(", ") }
                argument.write(to: &text)
            }
            text.append(")")
        case .unsupported(let name): text.append(name)
        }
    }
}

/// Reads `SwinsianRule`s from a keyed archive's property list.
enum SwinsianArchive {
    /// The owner's largest is under 2 KB.
    static let maximumBytes = 64 << 10
    static let maximumObjects = 2048
    /// References from the root to the deepest object, which bounds the reader's recursion.
    static let maximumDepth = 64
    static let maximumTextBytes = SmartRule.maximumTextBytes
    /// Objects read in all. One object can be listed many times at each level, so a small
    /// archive can name millions of parts; the owner's largest reads under 50.
    static let maximumReads = 4096

    /// The archive's root predicate, or why the archive can't be read.
    static func rule(_ archive: [UInt8]) -> Result<SwinsianRule, Problem> {
        guard archive.count <= maximumBytes else { return .failure(.tooLarge) }
        let plist: Any
        do {
            plist = try PropertyListSerialization.propertyList(from: Data(archive), format: nil)
        } catch {
            return .failure(.unreadable(error.localizedDescription))
        }
        guard let top = plist as? [String: Any],
            Set(top.keys) == ["$archiver", "$objects", "$top", "$version"],
            top["$archiver"] as? String == "NSKeyedArchiver",
            let objects = top["$objects"] as? [Any], let roots = top["$top"] as? [String: Any],
            roots.count == 1, let root = roots["root"].flatMap(objectNumber)
        else { return .failure(.notAnArchive) }
        if let problem = graphProblem(objects, root: root) { return .failure(problem) }
        let reader = Reader(objects: objects)
        let rule = reader.rule(roots["root"])
        return reader.reads > maximumReads ? .failure(.tooManyParts) : .success(rule)
    }

    /// Why the object graph from `root` is too big, too deep, cyclic or names an object that
    /// isn't there, or nil.
    private static func graphProblem(_ objects: [Any], root: Int) -> Problem? {
        guard objects.count <= maximumObjects else { return .tooManyObjects }
        // An object is a dictionary of references and values, or of arrays of them, such as
        // an array's `NS.objects`.
        let children = objects.map { object -> [Int] in
            guard let fields = object as? [String: Any] else { return [] }
            return fields.values.flatMap { value in
                (value as? [Any] ?? [value]).compactMap(objectNumber)
            }
        }
        // Object 0 is `$null`, which stands for nil and is never read.
        guard root >= 1, root < objects.count,
            children.allSatisfy({ $0.allSatisfy { $0 < objects.count } })
        else { return .notAnArchive }
        // Each object's height, by a walk with its own stack, so a deep archive can't overflow
        // this one.
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
    fileprivate static func objectNumber(_ value: Any) -> Int? {
        let object = value as AnyObject
        guard NSStringFromClass(type(of: object)) == "__NSCFType" else { return nil }
        let description = String(describing: object)
        guard description.hasPrefix("<CFKeyedArchiverUID "), description.hasSuffix("}"),
            let start = description.range(of: "{value = ")
        else { return nil }
        guard
            let number = Int(
                description[start.upperBound..<description.index(before: description.endIndex)]),
            number >= 0
        else { return nil }
        return number
    }

    /// Reads the objects of an archive whose graph `graphProblem` passed, so every reference is
    /// in range, there's no cycle, and recursion is at most `maximumDepth` deep. Past
    /// `maximumReads` it reads nothing more.
    private final class Reader {
        let objects: [Any]
        private(set) var reads = 0

        init(objects: [Any]) { self.objects = objects }

        /// Counts a read, and whether it's within the budget.
        private func read() -> Bool {
            reads += 1
            return reads <= maximumReads
        }

        func rule(_ value: Any?) -> SwinsianRule {
            guard read() else { return .unsupported("") }
            guard let (name, fields) = instance(value) else { return .unsupported("a value") }
            switch name {
            case "NSCompoundPredicate":
                guard let raw = unsigned(fields["NSCompoundPredicateType"]),
                    let type = NSCompoundPredicate.LogicalType(rawValue: raw),
                    let parts = array(fields["NSSubpredicates"])
                else { return .unsupported(name) }
                return .compound(type, parts.map(rule))
            case "NSComparisonPredicate":
                guard let (_, operation) = instance(fields["NSPredicateOperator"]),
                    let operatorType = unsigned(operation["NSOperatorType"]),
                    unsigned(operation["NSNegate"] ?? 0) == 0
                else { return .unsupported(name) }
                // String comparisons keep their options as flags.
                let options = unsigned(operation["NSFlags"] ?? operation["NSOptions"] ?? 0)
                guard let options, let modifier = unsigned(operation["NSModifier"] ?? 0) else {
                    return .unsupported(name)
                }
                return .comparison(
                    SwinsianComparison(
                        left: expression(fields["NSLeftExpression"]), operatorType: operatorType,
                        options: NSComparisonPredicate.Options(rawValue: options),
                        modifier: modifier, right: expression(fields["NSRightExpression"])))
            default: return .unsupported(name)
            }
        }

        func expression(_ value: Any?) -> SwinsianExpression {
            guard read() else { return .unsupported("") }
            guard let (name, fields) = instance(value) else { return .unsupported("a value") }
            switch name {
            case "NSKeyPathExpression":
                // `valueForKey:` on the evaluated object, with the key path as its argument.
                guard text(fields["NSSelectorName"]) == .text("valueForKey:"),
                    instance(fields["NSOperand"])?.name == "NSSelfExpression",
                    let arguments = array(fields["NSArguments"]), arguments.count == 1,
                    case .keyPath(let path) = expression(arguments[0])
                else { return .unsupported(name) }
                return .keyPath(path)
            case "NSKeyPathSpecifierExpression":
                guard case .text(let path) = text(fields["NSKeyPath"]) else {
                    return .unsupported(name)
                }
                return .keyPath(path)
            case "NSConstantValueExpression":
                let constant = fields["NSConstantValue"]
                if let number = number(constant) { return .number(number) }
                return text(constant) ?? .unsupported(name)
            case "NSFunctionExpression":
                // A built-in function such as `now()` is called on `_NSPredicateUtilities`.
                guard case .text(let function) = text(fields["NSSelectorName"]),
                    let (_, operand) = instance(fields["NSOperand"]),
                    text(operand["NSConstantValueClassName"]) == .text("_NSPredicateUtilities"),
                    let arguments = array(fields["NSArguments"])
                else { return .unsupported(name) }
                return .function(function, arguments.map(expression))
            default: return .unsupported(name)
            }
        }

        /// The object a reference names; nil for `$null` or anything but a reference. Objects
        /// are only reached by reference, so `graphProblem` bounds every path to one.
        private func object(_ value: Any?) -> Any? {
            guard let value, let number = SwinsianArchive.objectNumber(value), number != 0 else {
                return nil
            }
            return objects[number]
        }

        /// A string or number, by reference or stored in place.
        private func scalar(_ value: Any?) -> Any? { object(value) ?? value }

        /// An object's class name and fields.
        private func instance(_ value: Any?) -> (name: String, fields: [String: Any])? {
            guard let fields = object(value) as? [String: Any],
                let type = object(fields["$class"]) as? [String: Any],
                let name = type["$classname"] as? String
            else { return nil }
            return (name, fields)
        }

        private func array(_ value: Any?) -> [Any]? {
            guard let (name, fields) = instance(value),
                name == "NSArray" || name == "NSMutableArray"
            else { return nil }
            return fields["NS.objects"] as? [Any]
        }

        /// A string stored as itself or as an `NSString`, refused past `maximumTextBytes`.
        private func text(_ value: Any?) -> SwinsianExpression? {
            var string = scalar(value) as? String
            if string == nil, let (name, fields) = instance(value),
                name == "NSString" || name == "NSMutableString"
            {
                string = fields["NS.string"] as? String
            }
            guard let string else { return nil }
            let bytes = string.utf8.count
            return bytes > maximumTextBytes ? .longText(bytes) : .text(string)
        }

        private func number(_ value: Any?) -> Double? {
            guard let number = scalar(value) as? NSNumber, number.doubleValue.isFinite else {
                return nil
            }
            return number.doubleValue
        }

        private func unsigned(_ value: Any?) -> UInt? {
            number(value).flatMap { UInt(exactly: $0) }
        }
    }

    /// Why an archive can't be read.
    enum Problem: Error, Equatable, CustomStringConvertible {
        case tooLarge, notAnArchive, tooManyObjects, tooDeep, cycle, tooManyParts
        case unreadable(String)

        var description: String {
            switch self {
            case .tooLarge: "its rules are over \(maximumBytes) bytes"
            case .notAnArchive: "its rules aren't an archive Swinsian writes"
            case .tooManyObjects: "its rules are over \(maximumObjects) objects"
            case .tooDeep: "its rules nest deeper than \(maximumDepth)"
            case .cycle: "its rules refer to themselves"
            case .tooManyParts: "its rules have over \(maximumReads) parts"
            case .unreadable(let detail): "its rules couldn't be read: \(detail)"
            }
        }
    }
}
