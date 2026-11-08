import Foundation

/// The folded keys the catalog is looked up by, and the fold that makes them (ADR 0130). The
/// library's tags go through the same functions, so a lookup compares like with like: these
/// are the rules music-recommender's coverage count used on 2026-11-06.
enum CatalogKey {
    /// `text` lowercased, with accents and a leading "The" dropped, `&` as "and", a Discogs
    /// `(2)` suffix removed, and everything but letters and digits removed. A `title` also
    /// loses bracketed edition words, such as "(Remastered)" or "[Deluxe Edition]".
    static func fold(_ text: String, title: Bool = false) -> String {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = replacing(suffix, in: text)
        if title { text = replacing(editionWords, in: text) }
        text = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: "&", with: " and ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("the ") { text.removeFirst(4) }
        var folded = String.UnicodeScalarView()
        folded.append(contentsOf: text.unicodeScalars.filter(isKept))
        return String(folded)
    }

    /// The key the matcher compares titles by, music-recommender's too (ADR 0140): `fold`'s
    /// steps, but with `LatinFold`'s letters mapped first, so `æ`, `ø` and `ł` fold as the
    /// service folds them. Foundation's case and accent folding then handles every other
    /// character, so this is at least as lenient as `fold` for all scripts. The service
    /// lowercases the rest but keeps its marks, so it is the stricter side outside the table
    /// ("Việt" and "Viet" match here only).
    static func matchKey(_ text: String, title: Bool = false) -> String {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = replacing(suffix, in: text)
        if title { text = replacing(editionWords, in: text) }
        var mapped = ""
        for scalar in text.unicodeScalars {
            if let base = LatinFold.bases[scalar] {
                mapped += base
            } else {
                mapped.unicodeScalars.append(scalar)
            }
        }
        mapped = mapped.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: "&", with: " and ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if mapped.hasPrefix("the ") { mapped.removeFirst(4) }
        var folded = String.UnicodeScalarView()
        folded.append(contentsOf: mapped.unicodeScalars.filter(isKept))
        return String(folded)
    }

    /// `name` without the "(2)" Discogs adds to tell artists or labels of one name apart.
    static func withoutNumberSuffix(_ name: String) -> String { replacing(suffix, in: name) }

    /// The artist keys a credit of several artists can match: each name alone, and all of
    /// them run together with and without "and", so the library's "A & B" finds Discogs's
    /// [A, B]. Empty names are left out.
    static func artistKeys(_ names: [String]) -> Set<String> {
        let folded = names.map { fold($0) }.filter { !$0.isEmpty }
        var keys = Set(folded)
        if folded.count > 1 {
            keys.insert(folded.joined())
            keys.insert(folded.joined(separator: "and"))
        }
        return keys
    }

    /// The key a barcode is looked up by: its letters and digits, so "0 7464-63628-2 2" and
    /// "074646362822" are one. Empty for "none", which tags and Discogs both write for a
    /// release without one.
    static func barcode(_ text: String) -> String {
        let folded = fold(text)
        return folded == "none" ? "" : folded
    }

    /// The key a catalog number is looked up by, with its label's folded name. Nil for no
    /// number: Discogs writes "none" for a release without one.
    static func catalogNumber(_ text: String) -> String? {
        let folded = fold(text)
        return folded.isEmpty || folded == "none" ? nil : folded
    }

    /// The other spellings of a library album's title to look it up by, as music-recommender's
    /// prototype found them: without a leading bracketed catalog number, and without edition
    /// words after a dash. Each differs from `title` and from the others, and isn't empty.
    static func titleVariants(_ title: String) -> [String] {
        var variants: [String] = []
        for variant in [
            replacing(leadingBrackets, in: title), replacing(trailingEditionWords, in: title),
        ] {
            let trimmed = variant.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed != title, !variants.contains(trimmed) {
                variants.append(trimmed)
            }
        }
        return variants
    }

    private static func replacing(_ pattern: NSRegularExpression, in text: String) -> String {
        pattern.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    private static func isKept(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isAlphabetic || scalar.properties.numericType != nil
    }

    /// Discogs's suffix that tells apart artists or labels of the same name: "Soleil (2)".
    private static let suffix = regex(#"\s*\(\d+\)$"#)
    /// Words that name an edition of an album rather than the album.
    static let editionWordList =
        #"remaster\w*|deluxe|edition|sacd|expanded|anniversary|reissue|bonus|mono|stereo|special|limited|collector'?s|hi-?res|24[- ]?bit|\d+ ?khz|cd ?\d+|dis[ck] ?\d+"#
    /// A bracketed part of a title naming an edition rather than the album.
    private static let editionWords = regex(
        #"\s*[\[(][^\])]*\b("# + editionWordList + #")\b[^\])]*[\])]"#,
        options: .caseInsensitive)
    /// The same words after a dash at the end of a title: "Album - 2011 Remaster".
    private static let trailingEditionWords = regex(
        #"\s+[-–—]\s+[^-–—]*\b("# + editionWordList + #")\b[^-–—]*$"#,
        options: .caseInsensitive)
    /// A catalog number in brackets before a title: "[SK 032] Stockholm".
    private static let leadingBrackets = regex(#"^\s*\[[^\]]*\]\s*"#)

    private static func regex(_ pattern: String, options: NSRegularExpression.Options = [])
        -> NSRegularExpression
    {
        do {
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            preconditionFailure("\(pattern) isn't a regular expression: \(error)")
        }
    }
}
