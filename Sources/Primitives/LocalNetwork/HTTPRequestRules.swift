/// What the server does with a request's head, decided before anything touches the file system
/// (ADR 0039).
enum HTTPRoute: Equatable {
    case refuse(HTTPStatus)
    /// Serve the file a token names, the whole of it or `range`, its body only for a GET.
    case serve(token: String, range: ByteRangeRequest?, sendsBody: Bool)
}

enum HTTPStatus: Int, Equatable {
    case ok = 200
    case partialContent = 206
    case badRequest = 400
    case notFound = 404
    case methodNotAllowed = 405
    case rangeNotSatisfiable = 416
    case headersTooLarge = 431

    var reason: String {
        switch self {
        case .ok: "OK"
        case .partialContent: "Partial Content"
        case .badRequest: "Bad Request"
        case .notFound: "Not Found"
        case .methodNotAllowed: "Method Not Allowed"
        case .rangeNotSatisfiable: "Range Not Satisfiable"
        case .headersTooLarge: "Request Header Fields Too Large"
        }
    }
}

/// One `Range: bytes=` spec, before the file's size is known.
enum ByteRangeRequest: Equatable {
    /// `first-` or `first-last`.
    case from(UInt64, through: UInt64?)
    /// `-count`: the last `count` bytes.
    case suffix(UInt64)

    /// The bytes it asks for in a file of `size`; nil when they're outside it.
    func bytes(inFileOf size: UInt64) -> ClosedRange<UInt64>? {
        switch self {
        case .from(let first, let last):
            guard first < size else { return nil }
            return first...min(last ?? size - 1, size - 1)
        case .suffix(let count):
            guard count > 0, size > 0 else { return nil }
            return (size - min(count, size))...(size - 1)
        }
    }
}

/// A token is 32 hex digits, so anything else is refused without a lookup.
let tokenLength = 32

/// The route for `head`, the bytes after it `extra`, on a server bound to `authority`.
func route(_ head: HTTPHead, extra: Int, authority: String) -> HTTPRoute {
    let method = head.start[0]
    guard method == "GET" || method == "HEAD" else { return .refuse(.methodNotAllowed) }
    guard head.start[2] == HTTPHead.version || head.start[2] == "HTTP/1.0" else {
        return .refuse(.badRequest)
    }
    // DNS rebinding: a page that resolved its own name to this address still sends its name.
    guard let host = head.value("host"), host.lowercased() == authority.lowercased() else {
        return .refuse(.badRequest)
    }
    let lengths = head.values(HTTPHead.contentLength)
    guard extra == 0, head.values(HTTPHead.transferEncoding).isEmpty,
        lengths.isEmpty || lengths == ["0"]
    else { return .refuse(.badRequest) }
    let target = head.start[1]
    let token = target.dropFirst()
    guard target.first == "/", token.count == tokenLength,
        token.utf8.allSatisfy({ isHexDigit($0) })
    else { return .refuse(.notFound) }
    let ranges = head.values("range")
    guard ranges.count <= 1 else { return .refuse(.rangeNotSatisfiable) }
    var range: ByteRangeRequest?
    if let text = ranges.first {
        guard let parsed = byteRange(text) else { return .refuse(.rangeNotSatisfiable) }
        range = parsed
    }
    return .serve(token: String(token), range: range, sendsBody: method == "GET")
}

/// What the server answers `request` with for a file of `size` bytes, from its head alone: the
/// status, and the bytes it sends. Nil while the head is incomplete. The fuzzer drives the head
/// parser and the range rules through this, as a request on the wire would.
package func answer(toRequest request: [UInt8], authority: String, fileSize size: UInt64)
    -> (status: Int, bytes: ClosedRange<UInt64>?)?
{
    switch HTTPHead.parse(request[...], cap: HTTPServer<Int>.requestHeadCap) {
    case .incomplete: return nil
    case .tooLarge: return (HTTPStatus.headersTooLarge.rawValue, nil)
    case .malformed: return (HTTPStatus.badRequest.rawValue, nil)
    case .head(let head, let length):
        switch route(head, extra: request.count - length, authority: authority) {
        case .refuse(let status): return (status.rawValue, nil)
        case .serve(_, let range, _):
            guard let range else {
                return (HTTPStatus.ok.rawValue, size == 0 ? nil : 0...(size - 1))
            }
            guard let bytes = range.bytes(inFileOf: size) else {
                return (HTTPStatus.rangeNotSatisfiable.rawValue, nil)
            }
            return (HTTPStatus.partialContent.rawValue, bytes)
        }
    }
}

/// `bytes=first-last`, `bytes=first-` or `bytes=-count`; nil for anything else, a list of
/// ranges included.
func byteRange(_ text: String) -> ByteRangeRequest? {
    guard text.hasPrefix("bytes="), !text.contains(",") else { return nil }
    let spec = text.dropFirst("bytes=".count).split(
        separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
    guard spec.count == 2, spec.allSatisfy({ $0.utf8.allSatisfy(isDigit) }) else { return nil }
    let first = spec[0].isEmpty ? nil : UInt64(spec[0])
    let last = spec[1].isEmpty ? nil : UInt64(spec[1])
    switch (spec[0].isEmpty, spec[1].isEmpty) {
    case (true, false): return last.map { .suffix($0) }
    case (false, true): return first.map { .from($0, through: nil) }
    case (false, false):
        guard let first, let last, first <= last else { return nil }
        return .from(first, through: last)
    case (true, true): return nil
    }
}

private func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }

private func isHexDigit(_ byte: UInt8) -> Bool {
    isDigit(byte) || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f"))
}
