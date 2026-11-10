import Foundation

/// How much an album's track titles say on their own (ADR 0174): a title that fits its track
/// proves little when it's "Untitled 3", "Track 05" or "A2", or when the album's other titles
/// are the same but for a number, so the lengths have to vouch for the match instead.
enum TitleDistinctness {
    /// The share, from 0 to 1, of `titles` that are distinctive: at least `letters` letters
    /// left once numbers, side positions, Roman numerals and placeholder words are taken out,
    /// and no other title of the album left the same. None for no titles.
    static func share(_ titles: [String?]) -> Double {
        guard !titles.isEmpty else { return 0 }
        let rests = titles.map(rest)
        let counts = Dictionary(rests.map { ($0, 1) }, uniquingKeysWith: +)
        let distinctive = rests.count { rest in
            counts[rest] == 1
                && rest.unicodeScalars.count(where: \.properties.isAlphabetic) >= letters
        }
        return Double(distinctive) / Double(titles.count)
    }

    /// The fewest letters a distinctive title keeps.
    static let letters = 3

    /// What's left of `title` to tell it by: its words folded, without placeholders.
    static func rest(_ title: String?) -> String {
        (title ?? "").components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { CatalogKey.matchKey($0) }
            .filter { !$0.isEmpty && !isPlaceholder($0) }
            .joined(separator: " ")
    }

    /// A folded word that tells no track from another: a number, a side position as "a1" or
    /// "cd2", a Roman numeral, or a word every untitled track is named with.
    private static func isPlaceholder(_ word: String) -> Bool {
        if word.allSatisfy(\.isNumber) || placeholderWords.contains(word) { return true }
        let range = NSRange(word.startIndex..., in: word)
        return positionOrNumeral.firstMatch(in: word, range: range) != nil
    }

    private static let placeholderWords = Set(
        "untitled unnamed untitle track tracks titel title piste part pt side intro outro interlude skit song unknown hidden bonus the"
            .split(separator: " ").map(String.init))
    private static let positionOrNumeral: NSRegularExpression = {
        do {
            return try NSRegularExpression(pattern: #"^([a-z]{1,2}\d+|x{0,3}(ix|iv|v?i{0,3}))$"#)
        } catch {
            preconditionFailure("the placeholder pattern isn't a regular expression: \(error)")
        }
    }()
}
