@testable import Settings

/// The owner's layout (ADR 0128), which was the "Like my library" preset and is no preset now
/// that the app is shared: the YATE preset with `GENRE` as `{genre} - {styles}`, `GROUPING` the
/// labels, and the fields the survey didn't measure filling only empty tags, so it never
/// overwrites them. Compilation and the disc subtitle are off.
let ownersLayout: NamedDiscogsMapping = {
    var mapping = DiscogsPreset.yate.mapping
    mapping[.genres].format.template =
        DiscogsField.firstGenreToken + " - " + DiscogsField.styles.token
    mapping[.label].targets = [.field(.publisher), .field(.grouping)]
    for field: DiscogsField in [
        .title, .trackNumber, .trackCount, .discNumber, .discCount, .composer, .conductor,
        .lyricist, .remixer,
    ] {
        mapping[field].mode = .fillEmpty
    }
    mapping[.compilation].mode = .off
    mapping[.discSubtitle].mode = .off
    precondition(mapping.problem() == nil, "the owner's layout has a problem")
    return NamedDiscogsMapping(name: "Like my library", mapping: mapping)
}()
