import Foundation
import Settings

/// How every reply is decoded: strictly, each object with exactly its own keys. A field that
/// may be null is still there; a missing one, an unknown one or a wrong type fails the reply.
let replyDecoder = JSONDecoder()

/// A 200's body as `Reply`, or the refusal it holds when `ok` is false.
package func decodeReply<Reply: Decodable>(_ body: [UInt8], as _: Reply.Type)
    throws(RecommenderError.Kind) -> Reply
{
    do {
        if try replyDecoder.decode(OKFlag.self, from: Data(body)).ok {
            return try replyDecoder.decode(Reply.self, from: Data(body))
        }
        throw RecommenderError.Kind.refused(
            try replyDecoder.decode(RefusalReply.self, from: Data(body)).error)
    } catch let error as RecommenderError.Kind {
        throw error
    } catch let error as UnknownJobState {
        throw .unknownState(error.name)
    } catch let error as DecodingError {
        throw .unreadable(why(error))
    } catch {
        throw .unreadable("\(error)")
    }
}

/// `decoder`'s object, checked to have no key but `Keys`. Every reply type's `init(from:)`
/// starts with it, and `decodeReply` has read `ok` already.
func strictContainer<Keys: CodingKey & CaseIterable>(_ decoder: any Decoder, _: Keys.Type) throws
    -> KeyedDecodingContainer<Keys>
{
    try rejectUnknownKeys(decoder, Keys.self)
    return try decoder.container(keyedBy: Keys.self)
}

/// Thrown by a job's decoding for a state this player doesn't have.
struct UnknownJobState: Error {
    var name: String
}

/// Whether the reply says `ok`; read before its shape is known.
private struct OKFlag: Decodable {
    var ok: Bool
}

/// `{"ok": false, "error": {...}}`.
private struct RefusalReply: Decodable {
    var error: ServiceRefusal

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case ok, error
    }

    init(from decoder: any Decoder) throws {
        let container = try strictContainer(decoder, CodingKeys.self)
        error = try container.decode(ServiceRefusal.self, forKey: .error)
    }
}

/// A decoding error in a line: what was wrong, and where.
private func why(_ error: DecodingError) -> String {
    let (context, what): (DecodingError.Context, String) =
        switch error {
        case .keyNotFound(let key, let context): (context, "no \(key.stringValue.debugDescription)")
        case .typeMismatch(_, let context): (context, context.debugDescription)
        case .valueNotFound(_, let context): (context, context.debugDescription)
        case .dataCorrupted(let context): (context, context.debugDescription)
        @unknown default: (DecodingError.Context(codingPath: [], debugDescription: ""), "\(error)")
        }
    let path = context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }
    return path.isEmpty ? what : "\(path.joined(separator: ".")): \(what)"
}
