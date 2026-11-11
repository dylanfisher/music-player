import Foundation
import IOKit.pwr_mgt

/// The two IOKit calls behind `SleepAssertion`. Tests pass ones that record what they're asked.
struct SleepAssertionCalls: Sendable {
    /// Takes a `PreventUserIdleSystemSleep` assertion named `name`: its ID, or the IOReturn the
    /// create failed with.
    var create: @Sendable (_ name: String) -> Result<IOPMAssertionID, SleepAssertionFailure>
    var release: @Sendable (IOPMAssertionID) -> IOReturn

    /// Idle sleep only: the display still sleeps, and closing the lid, choosing Sleep or a low
    /// battery still sleep the Mac (ADR 0197).
    static let live = SleepAssertionCalls(
        create: { name in
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertPreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn), name as CFString, &id)
            return result == kIOReturnSuccess ? .success(id) : .failure(.init(code: result))
        },
        release: { IOPMAssertionRelease($0) })
}

/// An IOKit power call that didn't succeed, by its IOReturn.
struct SleepAssertionFailure: Error, Equatable, CustomStringConvertible {
    let code: IOReturn

    var description: String { "IOReturn " + String(format: "0x%08x", UInt32(bitPattern: code)) }
}
