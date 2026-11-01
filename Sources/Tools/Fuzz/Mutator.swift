import Fixtures

/// Changes an input the way libFuzzer's mutators do: bit flips, edge-case values written over
/// sizes and counts, ranges deleted, repeated or spliced in from another input, and the target's
/// own tokens. The same seed gives the same mutations.
struct Mutator {
    var random: SplitMix64
    /// The longest input it makes.
    let maximumBytes: Int
    let tokens: [[UInt8]]

    init(seed: UInt64, maximumBytes: Int, tokens: [[UInt8]]) {
        random = SplitMix64(seed: seed)
        self.maximumBytes = maximumBytes
        self.tokens = tokens
    }

    /// `input` with one to five mutations stacked; `other` is another corpus entry to splice from.
    mutating func mutate(_ input: [UInt8], splicing other: [UInt8]) -> [UInt8] {
        var bytes = input
        for _ in 0..<Int.random(in: 1...5, using: &random) {
            mutateOnce(&bytes, other)
        }
        if bytes.count > maximumBytes { bytes.removeLast(bytes.count - maximumBytes) }
        return bytes
    }

    private static let interesting8: [UInt8] = [0, 1, 0x7F, 0x80, 0xFF]
    private static let interesting32: [UInt32] = [
        0, 1, 2, 4, 8, 16, 0x7F, 0x80, 0xFF, 0x100, 0x7FFF, 0x8000, 0xFFFF, 0x1_0000,
        0x7FFF_FFFF, 0x8000_0000, 0xFFFF_FFFE, 0xFFFF_FFFF,
    ]

    private mutating func mutateOnce(_ bytes: inout [UInt8], _ other: [UInt8]) {
        switch Int.random(in: 0..<11, using: &random) {
        case 0 where !bytes.isEmpty:
            bytes[offset(bytes)] ^= 1 << UInt8.random(in: 0..<8, using: &random)
        case 1 where !bytes.isEmpty:
            bytes[offset(bytes)] = UInt8.random(in: 0...255, using: &random)
        case 2 where !bytes.isEmpty:
            bytes[offset(bytes)] = random.pick(Self.interesting8)
        case 3:
            let value = random.chance(0.5) ? random.pick(Self.interesting32) : UInt32(bytes.count)
            overwrite(&bytes, word(value))
        case 4 where bytes.count >= 4:
            // A size or count off by a little, in either byte order.
            let at = Int.random(in: 0...bytes.count - 4, using: &random)
            let littleEndian = random.chance(0.5)
            var value = UInt32(0)
            for index in 0..<4 {
                let byte = UInt32(bytes[at + (littleEndian ? 3 - index : index)])
                value = value << 8 | byte
            }
            value = value &+ UInt32(bitPattern: Int32.random(in: -16...16, using: &random))
            for index in 0..<4 {
                let byte = UInt8(truncatingIfNeeded: value >> (24 - 8 * index))
                bytes[at + (littleEndian ? 3 - index : index)] = byte
            }
        case 5 where !bytes.isEmpty:
            let range = self.range(in: bytes.count)
            bytes.removeSubrange(range)
        case 6 where !bytes.isEmpty:
            let range = self.range(in: bytes.count)
            bytes.insert(
                contentsOf: bytes[range], at: Int.random(in: 0...bytes.count, using: &random))
        case 7 where !other.isEmpty:
            let range = self.range(in: other.count)
            bytes.insert(
                contentsOf: other[range], at: Int.random(in: 0...bytes.count, using: &random))
        case 8 where !other.isEmpty && !bytes.isEmpty:
            // Crossover: this input's start, the other's end.
            let cut = Int.random(in: 0...min(bytes.count, other.count), using: &random)
            bytes = Array(bytes[..<min(cut, bytes.count)]) + other[cut...]
        case 9 where !tokens.isEmpty:
            let token = random.pick(tokens)
            if random.chance(0.5) {
                bytes.insert(contentsOf: token, at: Int.random(in: 0...bytes.count, using: &random))
            } else {
                overwrite(&bytes, token)
            }
        case 10 where !bytes.isEmpty:
            bytes.removeLast(Int.random(in: 1...bytes.count, using: &random))
        default:
            bytes.append(UInt8.random(in: 0...255, using: &random))
        }
    }

    private mutating func offset(_ bytes: [UInt8]) -> Int {
        Int.random(in: 0..<bytes.count, using: &random)
    }

    /// Mostly short ranges, as most sizes and fields are.
    private mutating func range(in count: Int) -> Range<Int> {
        let start = Int.random(in: 0..<count, using: &random)
        let longest = random.chance(0.8) ? min(16, count - start) : count - start
        return start..<start + Int.random(in: 1...longest, using: &random)
    }

    private mutating func word(_ value: UInt32) -> [UInt8] {
        let bigEndian = (0..<4).map { UInt8(truncatingIfNeeded: value >> (24 - 8 * $0)) }
        let width = random.pick([1, 2, 4])
        let bytes = Array(bigEndian.suffix(width))
        return random.chance(0.5) ? bytes : bytes.reversed()
    }

    private mutating func overwrite(_ bytes: inout [UInt8], _ token: [UInt8]) {
        guard bytes.count >= token.count else {
            bytes.append(contentsOf: token)
            return
        }
        let at = Int.random(in: 0...bytes.count - token.count, using: &random)
        bytes.replaceSubrange(at..<at + token.count, with: token)
    }
}
