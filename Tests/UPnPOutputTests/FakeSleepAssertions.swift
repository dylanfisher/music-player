import Foundation

@testable import UPnPOutput

/// Stands in for the IOKit power calls: records each create and release, and how many were
/// held at once at most, so no test takes a real assertion.
final class FakeSleepAssertions: @unchecked Sendable {
    private let lock = NSLock()
    private var nextID: UInt32 = 1
    private var live: Set<UInt32> = []
    private var names: [String] = []
    private var mostHeld = 0
    private var releasedUnknown = 0
    /// What the next creates fail with, as an IOReturn; nil to succeed.
    var failCreatesWith: Int32? {
        get { lock.withLock { failure } }
        set { lock.withLock { failure = newValue } }
    }
    private var failure: Int32?

    var calls: SleepAssertionCalls {
        SleepAssertionCalls(
            create: { name in
                self.lock.withLock {
                    self.names.append(name)
                    if let code = self.failure {
                        return .failure(SleepAssertionFailure(code: code))
                    }
                    let id = self.nextID
                    self.nextID += 1
                    self.live.insert(id)
                    self.mostHeld = max(self.mostHeld, self.live.count)
                    return .success(id)
                }
            },
            release: { id in
                self.lock.withLock {
                    if self.live.remove(id) == nil { self.releasedUnknown += 1 }
                    return 0
                }
            })
    }

    /// Assertions held now.
    var held: Int { lock.withLock { live.count } }
    /// Every create asked for, by name, in order, failed ones included.
    var created: [String] { lock.withLock { names } }
    var most: Int { lock.withLock { mostHeld } }
    /// Releases of an ID that wasn't held: a second release, or one never created.
    var badReleases: Int { lock.withLock { releasedUnknown } }
}
