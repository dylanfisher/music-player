/// A file as the index last saw it: its size and modification time, as the directory walk reads
/// them. A tag edit changes one or the other, so what was made from the file before, a
/// thumbnail or an analysis, isn't served for it again.
public struct FileStamp: Hashable, Sendable {
    public var sizeBytes: Int
    public var modifiedSeconds: Double

    public init(sizeBytes: Int, modifiedSeconds: Double) {
        self.sizeBytes = sizeBytes
        self.modifiedSeconds = modifiedSeconds
    }
}
