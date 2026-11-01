/// A file whose stats a scan gave to its new path, matching it as moved (ADR 0026).
struct TrackMove: Equatable, Sendable {
    var from: String
    var to: String
}
