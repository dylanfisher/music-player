/// The letters the matcher folds to plain ASCII, as music-recommender folds them (ADR 0140):
/// Latin-1 Supplement and Latin Extended-A, U+00C0 to U+017F less `×` and `÷`, each to its
/// lowercase base. `CatalogKey.matchKey` folds a letter outside it with Foundation.
enum LatinFold {
    /// Each base and the letters folded to it, in the order of the shared golden file.
    static let table: [(base: String, letters: String)] = [
        ("a", "ÀÁÂÃÄÅàáâãäåĀāĂăĄą"),
        ("ae", "Ææ"),
        ("c", "ÇçĆćĈĉĊċČč"),
        ("d", "ÐðĎďĐđ"),
        ("e", "ÈÉÊËèéêëĒēĔĕĖėĘęĚě"),
        ("g", "ĜĝĞğĠġĢģ"),
        ("h", "ĤĥĦħ"),
        ("i", "ÌÍÎÏìíîïĨĩĪīĬĭĮįİı"),
        ("ij", "Ĳĳ"),
        ("j", "Ĵĵ"),
        ("k", "Ķķĸ"),
        ("l", "ĹĺĻļĽľĿŀŁł"),
        ("n", "ÑñŃńŅņŇňŉŊŋ"),
        ("o", "ÒÓÔÕÖØòóôõöøŌōŎŏŐő"),
        ("oe", "Œœ"),
        ("r", "ŔŕŖŗŘř"),
        ("s", "ŚśŜŝŞşŠšſ"),
        ("ss", "ß"),
        ("t", "ŢţŤťŦŧ"),
        ("th", "Þþ"),
        ("u", "ÙÚÛÜùúûüŨũŪūŬŭŮůŰűŲų"),
        ("w", "Ŵŵ"),
        ("y", "ÝýÿŶŷŸ"),
        ("z", "ŹźŻżŽž"),
    ]

    /// `table` by letter.
    static let bases: [Unicode.Scalar: String] = Dictionary(
        uniqueKeysWithValues: table.flatMap { base, letters in
            letters.unicodeScalars.map { ($0, base) }
        })
}
