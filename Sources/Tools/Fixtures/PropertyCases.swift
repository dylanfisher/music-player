import Foundation

/// How many cases each property test runs: `PROPERTY_CASES` from the environment, or 50.
/// `scripts/sanitize` runs 1,000.
public let propertyCaseCount: Int = environmentNumber("PROPERTY_CASES") ?? 50

/// The seed of the first case; case n is seeded with this plus n. `PROPERTY_SEED` with
/// `PROPERTY_CASES=1` runs one failing case again.
public let propertyFirstSeed: UInt64 = environmentNumber("PROPERTY_SEED") ?? 0x14D

private func environmentNumber<T: FixedWidthInteger>(_ name: String) -> T? {
    guard let text = ProcessInfo.processInfo.environment[name] else { return nil }
    guard let number = T(text), number >= 0 else {
        preconditionFailure("\(name) must be a whole number, not \(text)")
    }
    return number
}

/// A property case that failed, with the seed that repeats it.
public struct PropertyFailure: Error, CustomStringConvertible {
    public let property: String
    public let seed: UInt64
    public let underlying: any Error

    public var description: String {
        "\(property) failed with seed \(seed) (rerun with PROPERTY_SEED=\(seed) PROPERTY_CASES=1):"
            + " \(underlying)"
    }
}

/// Runs `body` once per case, each with a generator of its own seed. The first case that throws
/// stops the run, and its error is wrapped with the seed.
public func forEachPropertyCase(
    _ property: String, _ body: (_ random: inout SplitMix64) throws -> Void
) throws {
    for offset in 0..<UInt64(propertyCaseCount) {
        let seed = propertyFirstSeed &+ offset
        var random = SplitMix64(seed: seed)
        do {
            try body(&random)
        } catch {
            throw PropertyFailure(property: property, seed: seed, underlying: error)
        }
    }
}
