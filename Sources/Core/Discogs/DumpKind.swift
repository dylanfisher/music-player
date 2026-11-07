/// The four dumps the catalog is built from, in the order they're imported: the smallest
/// first, so a bad set fails before the releases' hour.
public enum DumpKind: String, CaseIterable, Sendable {
    case labels, artists, masters, releases
}
