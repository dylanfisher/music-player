import Foundation

/// Random access to a file's bytes. Tests read from memory through the same parsers.
package protocol ByteSource {
    var size: Int { get }
    /// Reads `range`, which lies inside `0..<size`.
    func read(_ range: Range<Int>) throws(ParseFailure) -> [UInt8]
    /// `read` into `Data`, for bytes that leave as `Data`.
    func readData(_ range: Range<Int>) throws(ParseFailure) -> Data
}

extension ByteSource {
    package func readData(_ range: Range<Int>) throws(ParseFailure) -> Data {
        Data(try read(range))
    }
}
