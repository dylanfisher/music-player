import Foundation
import Testing

@testable import Library

/// Runs the controller for `windows` windows against a NAS whose throughput at each level is
/// `filesPerSecond`, with each measurement scaled by `noise`. Returns the level of each window.
private func run(
    _ controller: inout ReadConcurrency, windows: Int, noise: () -> Double = { 1 },
    _ filesPerSecond: (Int) -> Double
) -> [Int] {
    var levels: [Int] = []
    for _ in 0..<windows {
        let level = controller.level
        levels.append(level)
        let rate = filesPerSecond(level) * noise()
        // Little's law: with `level` files in flight, each takes level / rate seconds.
        controller.observe(.init(filesPerSecond: rate, secondsPerFile: Double(level) / rate))
    }
    return levels
}

/// A NAS that serves 12 files at once, 50 files/s each, and queues the rest.
private func saturatesAt12(_ level: Int) -> Double { 50 * Double(min(level, 12)) }

/// A NAS whose disks thrash past 8 files at once.
private func degradesPast8(_ level: Int) -> Double {
    level <= 8 ? 50 * Double(level) : max(100, 400 - 30 * Double(level - 8))
}

/// A deterministic ±`spread` factor, so a failing run repeats.
private struct Noise {
    var state: UInt64
    let spread: Double

    mutating func next() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let unit = Double(state >> 11) / Double(1 << 53)
        return 1 + spread * (unit * 2 - 1)
    }
}

@Test func climbsToANASThatSaturatesAt12AndSettlesThere() {
    var controller = ReadConcurrency()
    let levels = run(&controller, windows: 60, saturatesAt12)
    #expect(levels.prefix(4) == [4, 8, 16, 32])
    // Probes go one step either side and come back.
    #expect(levels.suffix(30).allSatisfy { (9...15).contains($0) })
    #expect(controller.trace == [4, 8, 16, 32, 16, 12])
}

@Test func findsThePeakOfANASThatDegradesPast8() {
    var controller = ReadConcurrency()
    let levels = run(&controller, windows: 60, degradesPast8)
    #expect(levels.suffix(30).allSatisfy { (6...10).contains($0) })
    #expect(controller.trace == [4, 8, 16, 8])
}

@Test func noisyMeasurementsStayNearTheBestLevel() {
    for seed: UInt64 in 1...20 {
        var noise = Noise(state: seed, spread: 0.15)
        var controller = ReadConcurrency()
        let levels = run(&controller, windows: 200, noise: { noise.next() }, saturatesAt12)
        let late = levels.suffix(100)
        // Near the best level, which any level from 12 up reaches, and never far from it.
        let mean = Double(late.reduce(0, +)) / Double(late.count)
        #expect((10...22).contains(mean), "seed \(seed): mean \(mean)")
        #expect(late.allSatisfy { (6...32).contains($0) }, "seed \(seed): \(Array(late))")
        // Throughput within 10% of the best the NAS can do.
        let throughput = late.map(saturatesAt12).reduce(0, +) / Double(late.count)
        #expect(throughput > 0.9 * saturatesAt12(12), "seed \(seed): \(throughput)")
        // Settled levels move a little at a time, not back and forth across the range.
        let settled = controller.trace.dropFirst(5)
        #expect(settled.allSatisfy { (6...32).contains($0) }, "seed \(seed): \(controller.trace)")
    }
}

@Test func backsOffWhenTheNASSlowsDown() {
    var controller = ReadConcurrency()
    _ = run(&controller, windows: 40, saturatesAt12)
    #expect(controller.trace.last == 12)
    // Another client takes most of the NAS: it now serves 4 files at once, at 25 files/s each.
    let levels = run(&controller, windows: 60) { 25 * Double(min($0, 4)) }
    #expect(levels[1] == 6, "the first window after the slowdown halves the level")
    #expect(levels.suffix(30).allSatisfy { (3...5).contains($0) })
}

@Test func backsOffWhenLatencyClimbsWithThroughputHeld() {
    var controller = ReadConcurrency()
    _ = run(&controller, windows: 40, saturatesAt12)
    #expect(controller.level == 12)
    controller.observe(.init(filesPerSecond: 600, secondsPerFile: 0.1))
    #expect(controller.level == 6)
    #expect(controller.phase == .climbing(from: nil))
}

@Test func staysInsideItsRange() {
    var linear = ReadConcurrency()
    _ = run(&linear, windows: 60) { 50 * Double($0) }
    #expect(linear.level == ReadConcurrency.networkRange.upperBound)

    var flat = ReadConcurrency()
    let levels = run(&flat, windows: 60) { _ in 100 }
    #expect(levels.allSatisfy { ReadConcurrency.networkRange.contains($0) })
    #expect(flat.level == ReadConcurrency.networkRange.lowerBound)

    var single = ReadConcurrency(range: 3...3, start: 8)
    #expect(run(&single, windows: 10, saturatesAt12).allSatisfy { $0 == 3 })
}
