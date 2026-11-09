/// A file whose stats a scan gave to its new path, matching it as moved (ADR 0026), or one
/// Keep Files Organized renamed (ADR 0160).
public struct TrackMove: Equatable, Sendable {
    public var from: String
    public var to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}
