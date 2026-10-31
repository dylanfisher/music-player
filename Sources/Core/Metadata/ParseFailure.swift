/// A `MetadataError` before it has a path. Parsers throw this; the entry points add the path.
struct ParseFailure: Error, Equatable {
    var kind: MetadataError.Kind
    var offset: Int?
    var detail: String

    static func malformed(at offset: Int, _ detail: String) -> ParseFailure {
        ParseFailure(kind: .malformed, offset: offset, detail: detail)
    }

    static func unsupported(at offset: Int?, _ detail: String) -> ParseFailure {
        ParseFailure(kind: .unsupported, offset: offset, detail: detail)
    }

    func error(path: String) -> MetadataError {
        MetadataError(path: path, kind: kind, offset: offset, detail: detail)
    }
}
