/// A command on timeline rows whose files are all gone from the library, so it has no track to
/// act on (ADR 0023).
public struct OnlyMissingFiles: Error, Equatable, CustomStringConvertible {
    public var description: String { "the selected plays' files aren't in the library" }
}
