import Foundation
import Testing

@testable import FuzzyMatch

private func score(_ query: String, _ text: String) -> Int? {
    FuzzyMatcher(query).score(FuzzyCandidate(text))
}

@Test func lettersMustAppearInOrder() {
    #expect(score("abc", "a big cat") != nil)
    #expect(score("cba", "a big cat") == nil)
    #expect(score("x", "") == nil)
}

@Test func theBonusesAndCostsAreSearchers() {
    // A run at the start: 10 + 6 + 6, plus 2 per letter from three letters.
    #expect(score("pro", "Projects") == 28)
    // The chain in pdf-reader-online: three word starts, 10 + 8 + 8.
    #expect(score("pro", "pdf-reader-online") == 26)
    // Initials beat a run of two letters: "gh" in GitHub against ghost.
    #expect(score("gh", "GitHub") == 18)
    #expect(score("gh", "ghost") == 16)
    // A whole component: the run plus 3 per letter.
    #expect(score("ab", "ab") == 22)
    #expect(score("ab", "ax-bx") == 18)
    #expect(score("abc", "x/abc") == 37)
    // A gap inside a word costs a flat 3, whatever its length.
    #expect(score("dl", "Downloads") == 10 - 3)
    // A gap into another word costs 3, 1 per skipped unit and 10, and the word start earns 8.
    #expect(score("ac", "xa cd") == 0 + 8 - 3 - 1 - 10)
    // Case and accents are folded.
    #expect(score("resume", "Résumé") == score("resume", "resume"))
}

@Test func highlightsPointAtTheOriginalText() throws {
    let candidate = FuzzyCandidate("old/docs")
    #expect(FuzzyMatcher("doc").highlights(candidate) == [NSRange(location: 4, length: 3)])
    #expect(
        FuzzyMatcher("e").highlights(FuzzyCandidate("Résumé")) == [NSRange(location: 1, length: 1)])
    let initials = try #require(FuzzyMatcher("nw").highlights(FuzzyCandidate("New Window")))
    #expect(initials == [NSRange(location: 0, length: 1), NSRange(location: 4, length: 1)])
}

/// The rules applied to one placement, as the doc comment states them: letters `0..<chain` use
/// the chain's scores, the rest the normal ones.
private func placementScore(_ positions: [Int], _ candidate: FuzzyCandidate, chain: Int) -> Int32 {
    let flags = candidate.flags
    func bonus(_ j: Int) -> Int32 {
        flags[j] & FuzzyCandidate.componentStart != 0
            ? 10 : flags[j] & FuzzyCandidate.wordStart != 0 ? 8 : 0
    }
    var total: Int32 = 0
    for (t, j) in positions.enumerated() {
        if t == 0 || t < chain {
            total += bonus(j)
            continue
        }
        let k = positions[t - 1]
        if k == j - 1 {
            total += bonus(j) > 0 ? bonus(j) : 6
        } else if !(k + 1...j).contains(where: { flags[$0] & FuzzyCandidate.wordStart != 0 }) {
            total += bonus(j) - 3
        } else {
            total += bonus(j) - 3 - Int32(j - k - 1) - 10
        }
    }
    return total
}

private func isChain(_ positions: ArraySlice<Int>, _ candidate: FuzzyCandidate) -> Bool {
    let flags = candidate.flags
    guard positions.allSatisfy({ flags[$0] & FuzzyCandidate.longWordStart != 0 }),
        let first = positions.first, let last = positions.last
    else { return false }
    return !(first + 1...max(first + 1, last)).contains {
        $0 <= last && flags[$0] & FuzzyCandidate.componentStart != 0
    }
}

/// Every placement of the query, scored by the rules, against the dynamic program.
@Test func theDynamicProgramFindsTheBestPlacement() {
    var seed: UInt64 = 79
    func next(_ bound: Int) -> Int {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((seed >> 33) % UInt64(bound))
    }
    let alphabet = Array("abAB -/")
    for _ in 0..<5000 {
        let text = String((0..<(1 + next(9))).map { _ in alphabet[next(alphabet.count)] })
        let query = String(
            (0..<(1 + next(3))).map { _ in "ab"[String.Index(utf16Offset: next(2), in: "ab")] })
        let candidate = FuzzyCandidate(text)
        let matcher = FuzzyMatcher(query)
        var best: Int32?
        func place(_ i: Int, _ from: Int, _ chosen: [Int]) {
            if i == matcher.units.count {
                let chainable = (1...chosen.count).last { isChain(chosen[..<$0], candidate) } ?? 0
                for chain in 0...chainable {
                    let s = placementScore(chosen, candidate, chain: chain)
                    best = max(best ?? s, s)
                }
                return
            }
            for j in from..<candidate.units.count where candidate.units[j] == matcher.units[i] {
                place(i + 1, j + 1, chosen + [j])
            }
        }
        place(0, 0, [])
        var expected = best.map(Int.init)
        // The prefix and whole-component scores.
        let n = matcher.units.count
        for start in candidate.units.indices
        where candidate.flags[start] & FuzzyCandidate.componentStart != 0
            && start + n <= candidate.units.count
            && Array(candidate.units[start..<(start + n)]) == matcher.units
        {
            var s = 10 + 6 * (n - 1) + (n >= 3 ? 2 * n : 0)
            if start + n == candidate.units.count || candidate.units[start + n] == 0x2F {
                s += 3 * n
            }
            expected = max(expected ?? s, s)
        }
        #expect(matcher.score(candidate) == expected, "\(query) in \(text)")
        if expected != nil {
            #expect(matcher.positions(candidate)?.count == n, "\(query) in \(text)")
        }
    }
}
