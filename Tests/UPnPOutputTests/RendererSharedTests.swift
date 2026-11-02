import Foundation
import Testing

@testable import LocalNetwork
@testable import UPnPOutput

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = 1000.0
    var now: Double { lock.withLock { time } }
    func advance(_ seconds: Double) { lock.withLock { time += seconds } }
}

@Test func aRetiredTokenServesUntilItsGraceRunsOut() {
    let clock = Clock()
    let shared = RendererShared(now: { clock.now })
    let file = HTTPServedFile(path: "/music/a.flac", contentType: "audio/flac")
    shared.serve(1, file)
    shared.serve(2, file)
    shared.retire(1)
    clock.advance(RendererShared.retiredGraceSeconds - 1)
    #expect(shared.file(1) == file)
    clock.advance(1)
    #expect(shared.file(1) == nil)
    // What's still in use never runs out.
    #expect(shared.file(2) == file)
    // Retiring again doesn't restart the grace.
    shared.retire(2)
    clock.advance(RendererShared.retiredGraceSeconds / 2)
    shared.retire(2)
    clock.advance(RendererShared.retiredGraceSeconds / 2)
    #expect(shared.file(2) == nil)
}
