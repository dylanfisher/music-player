import Foundation

/// A text prepared once for matching: folded to lowercase without accents, a Unicode scalar per
/// unit, with where each word and path component starts.
public struct FuzzyCandidate: Sendable {
    public let text: String
    let units: [UInt32]
    let flags: [UInt8]

    static let wordStart: UInt8 = 1
    static let componentStart: UInt8 = 2
    /// The first letter of a word of two or more letters, which an initials chain can use.
    static let longWordStart: UInt8 = 4
    static let separator: UInt8 = 8

    public init(_ text: String) {
        self.text = text
        let (units, flags) = fold(text)
        self.units = units
        self.flags = flags
    }
}

/// The folded scalars of `text` and their flags. A word starts at a letter or digit after
/// anything else, or at a capital after a lowercase letter; a component starts the text and
/// follows each "/".
private func fold(_ text: String) -> ([UInt32], [UInt8]) {
    var units: [UInt32] = []
    var flags: [UInt8] = []
    units.reserveCapacity(text.utf8.count)
    var previousWasWordChar = false
    var previousWasLower = false
    var afterSlash = true
    for character in text {
        let folded =
            character.isASCII
            ? String(character).lowercased()
            : String(character).folding(
                options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let isWordChar = character.isLetter || character.isNumber
        let startsWord =
            isWordChar && (!previousWasWordChar || (character.isUppercase && previousWasLower))
        for (offset, scalar) in folded.unicodeScalars.enumerated() {
            var flag: UInt8 = 0
            if offset == 0 {
                if startsWord { flag |= FuzzyCandidate.wordStart }
                if afterSlash { flag |= FuzzyCandidate.componentStart }
            }
            if !isWordChar { flag |= FuzzyCandidate.separator }
            units.append(scalar.value)
            flags.append(flag)
        }
        afterSlash = character == "/"
        previousWasWordChar = isWordChar
        previousWasLower = character.isLowercase
    }
    // A word of two or more units can start a chain.
    for index in units.indices where flags[index] & FuzzyCandidate.wordStart != 0 {
        let next = index + 1
        if next < units.count,
            flags[next] & (FuzzyCandidate.separator | FuzzyCandidate.wordStart) == 0
        {
            flags[index] |= FuzzyCandidate.longWordStart
        }
    }
    return (units, flags)
}

/// Fuzzy matching as Searcher's 0079 scores it: the query's letters in order; 10 for a letter at
/// the start of the text or of a path component, 8 at a word start, 6 right after the previous
/// matched letter; a gap inside a word costs 3, a gap into a later word 3 plus 1 per skipped
/// unit plus 10; an initials chain (word starts of words of two or more letters, in one
/// component) keeps its bonuses with no gap cost; a query of three or more letters that starts a
/// component scores 2 more per letter, and one equal to a whole component 3 more per letter.
public struct FuzzyMatcher: Sendable {
    static let componentStartBonus: Int32 = 10
    static let wordStartBonus: Int32 = 8
    static let runBonus: Int32 = 6
    static let gapPenalty: Int32 = 3
    static let newWordPenalty: Int32 = 10
    static let prefixBonus: Int32 = 2
    static let prefixLetters = 3
    static let wholeComponentBonus: Int32 = 3
    static let unreachable = Int32.min / 4

    public let query: String
    let units: [UInt32]

    public init(_ query: String) {
        self.query = query
        units = fold(query).0.filter { $0 != 0x20 }
    }

    public var isEmpty: Bool { units.isEmpty }

    /// The candidate's score, or nil when the letters aren't all there in order.
    public func score(_ candidate: FuzzyCandidate) -> Int? {
        var scratch = Scratch()
        return score(candidate, &scratch)
    }

    /// Scores every candidate, reusing one scratch, and passes each one that matches to `visit`
    /// with its index. For ranking thousands of candidates per key press.
    public func scoreAll(_ candidates: [FuzzyCandidate], _ visit: (Int, Int) -> Void) {
        var scratch = Scratch()
        for (index, candidate) in candidates.enumerated() {
            if let score = score(candidate, &scratch) { visit(index, score) }
        }
    }

    /// The matched letters, as UTF-16 ranges of the candidate's text, joined where adjacent; nil
    /// when it doesn't match.
    public func highlights(_ candidate: FuzzyCandidate) -> [NSRange]? {
        guard let positions = positions(candidate) else { return nil }
        // Each unit's UTF-16 range in the text: every unit of a character covers all of it.
        var unitRanges: [NSRange] = []
        var offset = 0
        for character in candidate.text {
            let length = character.utf16.count
            let folded =
                character.isASCII
                ? String(character).lowercased()
                : String(character).folding(
                    options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            for _ in folded.unicodeScalars {
                unitRanges.append(NSRange(location: offset, length: length))
            }
            offset += length
        }
        var ranges: [NSRange] = []
        for position in positions {
            let range = unitRanges[position]
            if let last = ranges.last, NSMaxRange(last) >= range.location {
                ranges[ranges.count - 1] = NSUnionRange(last, range)
            } else {
                ranges.append(range)
            }
        }
        return ranges
    }

    // MARK: Scoring

    private struct Scratch {
        var previousS: [Int32] = []
        var previousC: [Int32] = []
        var currentS: [Int32] = []
        var currentC: [Int32] = []

        mutating func reserve(_ count: Int) {
            guard previousS.count < count else { return }
            previousS = Array(repeating: 0, count: count)
            previousC = previousS
            currentS = previousS
            currentC = previousS
        }
    }

    private static func bonus(_ flags: UInt8) -> Int32 {
        if flags & FuzzyCandidate.componentStart != 0 { return componentStartBonus }
        if flags & FuzzyCandidate.wordStart != 0 { return wordStartBonus }
        return 0
    }

    private func score(_ candidate: FuzzyCandidate, _ scratch: inout Scratch) -> Int? {
        let n = candidate.units.count
        guard !units.isEmpty, n >= units.count, containsInOrder(candidate) else { return nil }
        scratch.reserve(n)
        var best = Self.unreachable
        candidate.units.withUnsafeBufferPointer { text in
            candidate.flags.withUnsafeBufferPointer { flags in
                fill(text, flags, &scratch, rows: nil) { row, s in
                    if row == units.count - 1 { best = max(best, s) }
                }
            }
        }
        best = max(best, prefixScore(candidate))
        return best > Self.unreachable ? Int(best) : nil
    }

    /// A quick reject: one pass that finds every query unit in order.
    private func containsInOrder(_ candidate: FuzzyCandidate) -> Bool {
        var next = 0
        for unit in candidate.units where unit == units[next] {
            next += 1
            if next == units.count { return true }
        }
        return false
    }

    /// Runs the dynamic program row by row, passing each reachable cell's best score to `cell`.
    /// With `rows`, also keeps every row's S and C tables, for finding the matched positions.
    private func fill(
        _ text: UnsafeBufferPointer<UInt32>, _ flags: UnsafeBufferPointer<UInt8>,
        _ scratch: inout Scratch, rows: UnsafeMutablePointer<[[Int32]]>?,
        cell: (Int, Int32) -> Void
    ) {
        let n = text.count
        let u = Self.unreachable
        for i in units.indices {
            let letter = units[i]
            var inWord = u
            var inWordPlusK = u
            var cross = u
            var chain = u
            for j in 0..<n {
                let flag = flags[j]
                if flag & FuzzyCandidate.wordStart != 0 {
                    cross = max(cross, inWordPlusK)
                    inWord = u
                    inWordPlusK = u
                }
                if flag & FuzzyCandidate.componentStart != 0 { chain = u }
                var s = u
                var c = u
                if text[j] == letter {
                    let bonus = Self.bonus(flag)
                    let canChain = flag & FuzzyCandidate.longWordStart != 0
                    if i == 0 {
                        s = bonus
                        if canChain { c = bonus }
                    } else {
                        if j > 0, scratch.previousS[j - 1] > u {
                            s = scratch.previousS[j - 1] + (bonus > 0 ? bonus : Self.runBonus)
                        }
                        if inWord > u { s = max(s, inWord - Self.gapPenalty + bonus) }
                        if cross > u {
                            // 3, plus 1 per unit skipped between k and j, plus 10.
                            s = max(
                                s,
                                cross - Int32(j) + 1 - Self.gapPenalty - Self.newWordPenalty + bonus
                            )
                        }
                        if canChain, chain > u { c = chain + bonus }
                        s = max(s, c)
                    }
                    if s > u { cell(i, s) }
                }
                scratch.currentS[j] = s
                scratch.currentC[j] = c
                if i > 0 {
                    let previous = scratch.previousS[j]
                    if previous > u {
                        inWord = max(inWord, previous)
                        inWordPlusK = max(inWordPlusK, previous + Int32(j))
                    }
                    if scratch.previousC[j] > u { chain = max(chain, scratch.previousC[j]) }
                }
            }
            // Row i is computed against row i - 1, so the running maxima above read k < j only
            // after this swap; for row 0 they are unused.
            swap(&scratch.previousS, &scratch.currentS)
            swap(&scratch.previousC, &scratch.currentC)
            rows?.pointee.append(Array(scratch.previousS[0..<n]))
            rows?.pointee.append(Array(scratch.previousC[0..<n]))
        }
    }

    /// The query typed in full at a component start: the run, plus the prefix bonus from three
    /// letters, plus the whole-component bonus when nothing else is in the component.
    private func prefixScore(_ candidate: FuzzyCandidate) -> Int32 {
        let count = units.count
        var best = Self.unreachable
        for start in candidate.units.indices
        where candidate.flags[start] & FuzzyCandidate.componentStart != 0
            && start + count <= candidate.units.count
            && candidate.units[start..<(start + count)].elementsEqual(units)
        {
            var score = Self.componentStartBonus + Self.runBonus * Int32(count - 1)
            if count >= Self.prefixLetters { score += Self.prefixBonus * Int32(count) }
            let end = start + count
            if end == candidate.units.count || candidate.units[end] == 0x2F {
                score += Self.wholeComponentBonus * Int32(count)
            }
            best = max(best, score)
        }
        return best
    }

    /// The units the best match uses, found by walking the kept tables back.
    func positions(_ candidate: FuzzyCandidate) -> [Int]? {
        guard let total = score(candidate) else { return nil }
        let count = units.count
        if Int32(total) == prefixScore(candidate) {
            let start = candidate.units.indices.first { start in
                candidate.flags[start] & FuzzyCandidate.componentStart != 0
                    && start + count <= candidate.units.count
                    && candidate.units[start..<(start + count)].elementsEqual(units)
            }!
            return Array(start..<(start + count))
        }
        var rows: [[Int32]] = []
        var scratch = Scratch()
        scratch.reserve(candidate.units.count)
        candidate.units.withUnsafeBufferPointer { text in
            candidate.flags.withUnsafeBufferPointer { flags in
                fill(text, flags, &scratch, rows: &rows) { _, _ in }
            }
        }
        let s = stride(from: 0, to: rows.count, by: 2).map { rows[$0] }
        let c = stride(from: 1, to: rows.count, by: 2).map { rows[$0] }
        guard var j = s[count - 1].firstIndex(of: Int32(total)) else { return nil }
        var positions = [j]
        var inChain = c[count - 1][j] == Int32(total)
        var target = Int32(total)
        for i in stride(from: count - 1, to: 0, by: -1) {
            let flags = candidate.flags
            let bonus = Self.bonus(flags[j])
            let found = (0..<j).reversed().first { k in
                if inChain {
                    return c[i - 1][k] > Self.unreachable && c[i - 1][k] + bonus == target
                        && !(k..<j).dropFirst().contains {
                            flags[$0] & FuzzyCandidate.componentStart != 0
                        }
                        && flags[j] & FuzzyCandidate.componentStart == 0
                }
                let previous = s[i - 1][k]
                guard previous > Self.unreachable else { return false }
                return transition(from: k, to: j, flags) + previous == target
            }
            guard let k = found else { return nil }
            target = inChain ? c[i - 1][k] : s[i - 1][k]
            if !inChain, c[i - 1][k] == target { inChain = true }
            j = k
            positions.append(k)
        }
        return positions.reversed()
    }

    /// What a letter at `j` adds after one at `k`, outside a chain.
    private func transition(from k: Int, to j: Int, _ flags: [UInt8]) -> Int32 {
        let bonus = Self.bonus(flags[j])
        if k == j - 1 { return bonus > 0 ? bonus : Self.runBonus }
        let sameWord = !(k + 1...j).contains { flags[$0] & FuzzyCandidate.wordStart != 0 }
        if sameWord { return bonus - Self.gapPenalty }
        return bonus - Self.gapPenalty - Int32(j - k - 1) - Self.newWordPenalty
    }
}
