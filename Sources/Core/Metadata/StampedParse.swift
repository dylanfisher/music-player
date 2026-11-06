/// A file's parse with the size and mtime the file had when it was parsed, so whoever stores
/// it later can tell whether the file changed since and the parse no longer applies: the tag
/// writer's read-back, handed to the library's rescan (ADR 0108).
public struct StampedParse: Equatable, Sendable {
    public var parsed: ParsedFile
    public var sizeBytes: Int
    public var modifiedNanoseconds: Int

    package init(parsed: ParsedFile, sizeBytes: Int, modifiedNanoseconds: Int) {
        self.parsed = parsed
        self.sizeBytes = sizeBytes
        self.modifiedNanoseconds = modifiedNanoseconds
    }
}
