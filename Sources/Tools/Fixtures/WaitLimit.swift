import Foundation

/// How long a test waits for something before it calls it hung. Tests on the main actor take
/// turns on it, so a wait also lasts through the work of the tests that run in between, and
/// `scripts/test` runs several targets at once (ADR 0182). A wait in a busy target passed 10
/// seconds that way, so the limit is far above how long anything should take.
let waitLimit: TimeInterval = 60
