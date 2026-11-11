import Testing

@testable import UPnPOutput

@Test func anAssertionIsTakenOncePerChangeToWantedAndReleasedOnTheChangeBack() {
    let fake = FakeSleepAssertions()
    let assertion = SleepAssertion(name: "Music Player playing to Den", calls: fake.calls)
    assertion.hold(false)
    #expect(fake.created == [])
    for _ in 0..<3 { assertion.hold(true) }
    #expect(fake.created == ["Music Player playing to Den"])
    #expect(fake.held == 1)
    assertion.hold(false)
    assertion.hold(false)
    #expect(fake.held == 0)
    assertion.hold(true)
    #expect(fake.created.count == 2)
    #expect(fake.most == 1)
    #expect(fake.badReleases == 0)
}

@Test func aFailedCreateHoldsNothingAndIsTriedAgainOnlyWhenWantedAgain() {
    let fake = FakeSleepAssertions()
    fake.failCreatesWith = Int32(bitPattern: 0xE000_02C2)
    let assertion = SleepAssertion(name: "Music Player playing to Den", calls: fake.calls)
    assertion.hold(true)
    assertion.hold(true)
    #expect(fake.created.count == 1)
    #expect(fake.held == 0)
    fake.failCreatesWith = nil
    assertion.hold(false)
    #expect(fake.badReleases == 0)
    assertion.hold(true)
    #expect(fake.created.count == 2)
    #expect(fake.held == 1)
}

@Test func nothingIsHeldAfterClose() {
    let fake = FakeSleepAssertions()
    let assertion = SleepAssertion(name: "Music Player playing to Den", calls: fake.calls)
    assertion.hold(true)
    assertion.close()
    #expect(fake.held == 0)
    assertion.hold(true)
    assertion.close()
    #expect(fake.held == 0)
    #expect(fake.created.count == 1)
    #expect(fake.badReleases == 0)
}

@Test func aFailureNamesItsIOReturnInHex() {
    #expect(
        "\(SleepAssertionFailure(code: Int32(bitPattern: 0xE000_02C2)))" == "IOReturn 0xe00002c2")
}

@Test func closeDoesNotWaitOnACreateUnderWayAndReleasesWhatItReturns() {
    let fake = FakeSleepAssertions()
    let box = AssertionBox()
    // The create closes the holder before it returns, as the main thread closing the output
    // while the session takes one would: a close that waited on the create would deadlock.
    let calls = SleepAssertionCalls(
        create: { name in
            box.assertion?.close()
            return fake.calls.create(name)
        },
        release: fake.calls.release)
    let assertion = SleepAssertion(name: "Music Player playing to Den", calls: calls)
    box.assertion = assertion
    assertion.hold(true)
    #expect(fake.created.count == 1)
    #expect(fake.held == 0)
    #expect(fake.badReleases == 0)
}

@Test func aHolderDroppedWithoutCloseReleasesWhatItHolds() {
    let fake = FakeSleepAssertions()
    var assertion: SleepAssertion? = SleepAssertion(
        name: "Music Player playing to Den", calls: fake.calls)
    assertion?.hold(true)
    #expect(fake.held == 1)
    assertion = nil
    #expect(fake.held == 0)
    #expect(fake.badReleases == 0)
}

/// Lets a stand-in call reach the holder it was given to.
private final class AssertionBox: @unchecked Sendable {
    weak var assertion: SleepAssertion?
}
