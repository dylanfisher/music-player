/// A `MetadataError` before it has a path. Parsers throw this; the entry points add the path.
package struct ParseFailure: Error, Equatable {
    package var kind: MetadataError.Kind
    package var offset: Int?
    package var detail: String

    package static func malformed(at offset: Int, _ detail: String) -> ParseFailure {
        ParseFailure(kind: .malformed, offset: offset, detail: detail)
    }

    package static func unsupported(at offset: Int?, _ detail: String) -> ParseFailure {
        ParseFailure(kind: .unsupported, offset: offset, detail: detail)
    }

    package func error(path: String) -> MetadataError {
        MetadataError(path: path, kind: kind, offset: offset, detail: detail)
    }
}
