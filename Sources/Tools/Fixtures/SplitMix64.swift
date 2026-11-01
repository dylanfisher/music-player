/// A seeded generator, so the same file count always plans the same library, and a fuzz run or a
/// property test repeats from its seed.
public struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// True with probability `p`.
    public mutating func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &self) < p }

    public mutating func pick<T>(_ options: [T]) -> T { options.randomElement(using: &self)! }

    /// One of `options`, each chosen in proportion to its weight.
    public mutating func pick<T>(weighted options: [(T, Int)]) -> T {
        var roll = Int.random(in: 0..<options.map(\.1).reduce(0, +), using: &self)
        for (option, weight) in options {
            if roll < weight { return option }
            roll -= weight
        }
        preconditionFailure("unreachable: the roll is below the total weight")
    }
}
