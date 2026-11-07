/// How alike an album's track titles are to a release's, folded as the catalog folds titles,
/// remembered per release title: a master's releases mostly share one tracklist.
final class TitleSimilarity {
    private let albumTitles: [[Unicode.Scalar]]
    private var known: [String: [Double]] = [:]

    init(_ titles: [String?]) {
        albumTitles = titles.map { Array(CatalogKey.fold($0 ?? "", title: true).unicodeScalars) }
    }

    /// The similarity, from 0 to 1, of each of the album's titles to `title`.
    func similarities(to title: String) -> [Double] {
        if let similarities = known[title] { return similarities }
        let folded = Array(CatalogKey.fold(title, title: true).unicodeScalars)
        let similarities = albumTitles.map { Self.similarity($0, folded) }
        known[title] = similarities
        return similarities
    }

    /// 1 for the same folded title, else one less the edit distance over the longer length,
    /// raised to `MatchThreshold.containedTitle` when one title holds the other. An empty
    /// title is like nothing.
    static func similarity(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 1 }
        let (shorter, longer) = a.count <= b.count ? (a, b) : (b, a)
        let ratio = 1 - Double(editDistance(a, b)) / Double(longer.count)
        guard shorter.count >= MatchThreshold.containedLetters, contains(longer, shorter) else {
            return ratio
        }
        return max(ratio, MatchThreshold.containedTitle)
    }

    private static func contains(_ text: [Unicode.Scalar], _ part: [Unicode.Scalar]) -> Bool {
        guard part.count <= text.count else { return false }
        for start in 0...(text.count - part.count)
        where text[start..<(start + part.count)].elementsEqual(part) {
            return true
        }
        return false
    }

    /// Levenshtein's distance, a row at a time.
    private static func editDistance(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Int {
        var previous = Array(0...b.count)
        var current = previous
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = min(
                    previous[j] + 1, current[j - 1] + 1,
                    previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
