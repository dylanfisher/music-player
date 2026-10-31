/// Random access to a file's bytes. Tests read from memory through the same parsers.
protocol ByteSource {
    var size: Int { get }
    /// Reads `range`, which lies inside `0..<size`.
    func read(_ range: Range<Int>) throws(ParseFailure) -> [UInt8]
}
