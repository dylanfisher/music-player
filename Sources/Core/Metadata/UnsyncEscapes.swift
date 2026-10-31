/// ID3 unsynchronisation writes a zero after every 0xFF so the tag never contains an MPEG sync
/// pattern. Removing those zeros shifts every later byte, so this records where each one was, to
/// map a byte of the decoded tag back to its place in the file.
struct UnsyncEscapes {
    /// Decoded indices that had a zero removed just before them, ascending.
    private var shiftedFrom: [Int] = []

    /// `raw` without its escapes, and where they were.
    static func decode(_ raw: [UInt8]) -> ([UInt8], UnsyncEscapes) {
        var decoded: [UInt8] = []
        decoded.reserveCapacity(raw.count)
        var escapes = UnsyncEscapes()
        var index = 0
        while index < raw.count {
            decoded.append(raw[index])
            if raw[index] == 0xFF, index + 1 < raw.count, raw[index + 1] == 0 {
                index += 1
                escapes.shiftedFrom.append(decoded.count)
            }
            index += 1
        }
        return (decoded, escapes)
    }

    /// The index in the raw bytes of decoded byte `index`.
    func rawIndex(_ index: Int) -> Int {
        var low = 0
        var high = shiftedFrom.count
        while low < high {
            let middle = (low + high) / 2
            if shiftedFrom[middle] <= index { low = middle + 1 } else { high = middle }
        }
        return index + low
    }
}
