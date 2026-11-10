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

    /// The key the matcher compares titles by, music-recommender's too (ADR 0148): `fold`'s
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

    /// The other spellings of a library album's title to look it up by. First as
    /// music-recommender's prototype found them: without a leading bracketed catalog number,
    /// and without edition words after a dash. Then the title cleaned a step at a time, each
    /// step a spelling (ADR 0174): a trailing format or disc word ("Vinyl", "WEB", "320",
    /// "CD2"), a trailing bracket with a digit or of format words ("[WIGCD 32]", "(2012)",
    /// "[EP]"), a leading one with a digit ("(T2x 07)"), and `artist`'s name before a dash.
    /// Each folds unlike `title` and the others, and isn't empty. They're only looked up
    /// besides the title, so a step that cuts a real title short adds candidates the
    /// tracklist then has to fit.
    static func titleVariants(_ title: String, artist: String? = nil) -> [String] {
        var variants: [String] = []
        var keys: Set<String> = [fold(title, title: true)]
        func add(_ variant: String) {
            let trimmed = variant.trimmingCharacters(in: separators)
            let key = fold(trimmed, title: true)
            guard !key.isEmpty, keys.insert(key).inserted else { return }
            variants.append(trimmed)
        }
        add(replacing(leadingBrackets, in: title))
        add(replacing(trailingEditionWords, in: title))
        let artistKeys = Set(artistNames(artist).map { fold($0) })
        var current = title.trimmingCharacters(in: separators)
        while let next = cleanedOnce(current, artistKeys: artistKeys) {
            current = next
            add(current)
        }
        return variants
    }

    /// The catalog numbers a title names in brackets, at its start or its end, as a library
    /// album with none in its tags often has them ("Ghost [WIGCD 32]", "(ACRE 021) Evelyn"):
    /// each as written, then without a trailing format word ("APNEA027-WEB" as "APNEA027").
    /// A bracket counts when it holds a letter and a digit, at most `catalogNumberLength`
    /// characters, and isn't a year or a disc ("CD 2").
    static func catalogNumbers(inTitle title: String) -> [String] {
        var numbers: [String] = []
        for pattern in [leadingBracket, trailingBracket] {
            guard let inner = firstGroup(pattern, in: title) else { continue }
            let number = inner.trimmingCharacters(in: .whitespaces)
            guard number.count <= catalogNumberLength,
                number.rangeOfCharacter(from: .letters) != nil,
                number.rangeOfCharacter(from: .decimalDigits) != nil,
                !matches(disc, number), !matches(formatOnly, number)
            else { continue }
            for spelled in [number, replacing(trailingFormatWord, in: number)] {
                let trimmed = spelled.trimmingCharacters(in: separators)
                if catalogNumber(trimmed) != nil, !numbers.contains(trimmed) {
                    numbers.append(trimmed)
                }
            }
        }
        return numbers
    }

    /// The longest bracket `catalogNumbers` reads as a catalog number.
    static let catalogNumberLength = 24

    /// `title` after the first cleaning step that changes it, or nil when none does.
    private static func cleanedOnce(_ title: String, artistKeys: Set<String>) -> String? {
        for pattern in [trailingFormatWord, trailingDisc] {
            let next = replacing(pattern, in: title).trimmingCharacters(in: separators)
            if next != title { return next }
        }
        if let inner = firstGroup(trailingBracket, in: title),
            inner.rangeOfCharacter(from: .decimalDigits) != nil || matches(formatOnly, inner)
        {
            return replacing(trailingBracket, in: title).trimmingCharacters(in: separators)
        }
        if let inner = firstGroup(leadingBracket, in: title),
            inner.rangeOfCharacter(from: .decimalDigits) != nil
        {
            return replacing(leadingBracket, in: title).trimmingCharacters(in: separators)
        }
        if let dash = title.range(of: #"\s+[-–—]\s+"#, options: .regularExpression) {
            let before = fold(String(title[..<dash.lowerBound]))
            if artistKeys.contains(before) || variousKeys.contains(before) {
                return String(title[dash.upperBound...]).trimmingCharacters(in: separators)
            }
        }
        return nil
    }

    /// What a cleaned title is trimmed of at both ends.
    private static let separators = CharacterSet.whitespaces.union(
        CharacterSet(charactersIn: "-–—_"))
    /// How a compilation's title can start before its dash: "VA - Title".
    private static let variousKeys: Set<String> = ["va", "various", "variousartists"]
    /// Words a release's format or a rip's quality is named by, that no album is titled by.
    private static let formatWordList =
        #"web|vinyl|320|v0|flac|mp3|cdr|cdm|cds|cd|lp|ep|promo|single|lossless|24[- ]?(bit|\d+)"#
    /// A format word at the end of a title, after a space, a dash or an underscore.
    private static let trailingFormatWord = regex(
        #"[\s_-]+("# + formatWordList + #")$"#, options: .caseInsensitive)
    /// A disc of a set at the end of a title, outside brackets: "CD2", "Disc One".
    private static let trailingDisc = regex(
        #"[\s_-]+(cd|dis[ck])\s?(\d+|one|two|three|four)$"#, options: .caseInsensitive)
    /// Text that is only format words, as a bracket's: "EP", "Vinyl", "CD 1 Mixed" isn't.
    private static let formatOnly = regex(
        #"^\s*(("# + formatWordList + #")[\s/,+-]*)+$"#, options: .caseInsensitive)
    /// A disc of a set, as a bracket holds it: "CD 2", "Disc 1".
    private static let disc = regex(#"^\s*(cd|dis[ck])\s?\d+\s*$"#, options: .caseInsensitive)
    /// A bracket at the end or the start of a title, its text the first group.
    private static let trailingBracket = regex(#"\s*[\[(]([^\[\]()]*)[\])]\s*$"#)
    private static let leadingBracket = regex(#"^\s*[\[(]([^\[\]()]*)[\])]\s*"#)

    private static func firstGroup(_ pattern: NSRegularExpression, in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let found = pattern.firstMatch(in: text, range: range),
            let group = Range(found.range(at: 1), in: text)
        else { return nil }
        return String(text[group])
    }

    private static func matches(_ pattern: NSRegularExpression, _ text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
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
