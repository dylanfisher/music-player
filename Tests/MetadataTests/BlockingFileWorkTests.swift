import Foundation
import Testing

@testable import Metadata

/// File access that never returns, as on a share that stopped answering, until `gate` opens.
private func hungAccess(_ started: DispatchSemaphore, _ gate: DispatchSemaphore) -> Bool {
    started.signal()
    gate.wait()
    return true
}

/// The main actor carries on while a file access hangs: the work holds a thread of its own. Run
/// on the main actor, this test could only go on past `started` if the access isn't on it.
@MainActor
@Test(.timeLimit(.minutes(1)))
func aHungFileAccessLeavesTheMainActorFree() async {
    let started = DispatchSemaphore(value: 0)
    let gate = DispatchSemaphore(value: 0)
    let access = Task { @MainActor in await blockingFileWork { hungAccess(started, gate) } }
    let begun = await blockingFileWork { started.wait(timeout: .now() + 10) == .success }
    #expect(begun, "the access never started")
    var mainActorRan = false
    await Task { @MainActor in mainActorRan = true }.value
    #expect(mainActorRan)
    gate.signal()
    #expect(await access.value)
}

@Test func aWaitAtQuitGivesUpOnWorkThatNeverReturns() {
    let started = DispatchSemaphore(value: 0)
    let gate = DispatchSemaphore(value: 0)
    let start = DispatchTime.now().uptimeNanoseconds
    #expect(!finishes(within: 0.2) { _ = hungAccess(started, gate) })
    let waited = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    #expect(waited >= 0.2 && waited < 5, "waited \(waited) s")
    gate.signal()
    #expect(finishes(within: 5) {})
}
