/// Where the loaded track is by the app's own clock, and when it's over by it (ADR 0112). A
/// renderer's positions can lag what it plays by seconds, so the end never waits on one: the
/// renderer's reports start the clock, pause and resume it, and show a stall, nothing more.
struct RendererClock: Equatable {
    /// How long past a track's end, by the clock, the app waits for the renderer to move on
    /// before it sends the next track itself.
    static let leadMarginSeconds = 2.0
    /// How much further behind than its usual lag a renderer may report before it counts as
    /// stalled: positions come in whole seconds, and a poll is up to a second old.
    static let behindToleranceSeconds = 1.5
    /// Polls in a row that find the renderer stalled before the end moves: one alone may be a
    /// slow reply.
    static let stalledPolls = 2
    /// The most that stalls move a track's end later, from a start or a seek, so a renderer that
    /// reports itself further and further behind can't hold the next track back for good.
    static let stallCapSeconds = 10.0

    /// The track's length in the file.
    let durationSeconds: Double
    private var anchorSeconds = 0.0
    private var anchorTime = 0.0
    private(set) var isRunning = false
    /// How much later than the track's length stalls have moved the end.
    private(set) var stallSeconds = 0.0
    /// `stallSeconds` when the lag was last measured from scratch, after a pause.
    private var stallBeforeSeconds = 0.0
    /// The least the renderer has been behind the clock since the lag was measured from
    /// scratch.
    private var lagSeconds: Double?
    private var behindPolls = 0

    init(durationSeconds: Double) { self.durationSeconds = durationSeconds }

    /// Seconds into the track at `now`, by the clock.
    func seconds(at now: Double) -> Double {
        anchorSeconds + (isRunning ? now - anchorTime : 0)
    }

    /// When the app moves on by itself: the track's end, moved by stalls, plus the margin. Nil
    /// while the clock is stopped.
    var deadline: Double? {
        guard isRunning else { return nil }
        return anchorTime + max(0, durationSeconds - anchorSeconds) + stallSeconds
            + Self.leadMarginSeconds
    }

    /// Whether the clock is within `slackSeconds` of the track's length, or past it, however far
    /// stalls moved the end: a stop now came at the end.
    func isAtEnd(at now: Double, slackSeconds: Double) -> Bool {
        seconds(at: now) + slackSeconds >= durationSeconds
    }

    /// Sets the clock to `seconds` at `now`, as a load, a seek or the renderer first playing
    /// does; what earlier polls measured no longer applies.
    mutating func set(_ seconds: Double, at now: Double, running: Bool) {
        self = RendererClock(durationSeconds: durationSeconds)
        anchorSeconds = seconds
        anchorTime = now
        isRunning = running
    }

    mutating func pause(at now: Double) {
        guard isRunning else { return }
        anchorSeconds = seconds(at: now)
        anchorTime = now
        isRunning = false
        // The renderer's lag may differ once it plays again, so it's measured again.
        stallBeforeSeconds = stallSeconds
        lagSeconds = nil
        behindPolls = 0
    }

    mutating func resume(at now: Double) {
        guard !isRunning else { return }
        anchorTime = now
        isRunning = true
    }

    /// A poll found the renderer playing at `polledSeconds`. When it's further behind the clock
    /// than its least lag by more than `behindToleranceSeconds`, `stalledPolls` running, while
    /// the clock is short of the end, it stalled, and the end moves later to match: never
    /// earlier, and by at most `stallCapSeconds`.
    mutating func polled(_ polledSeconds: Double, at now: Double) {
        guard isRunning else { return }
        let clockSeconds = seconds(at: now)
        // Behind the clock as stalls before a pause had already moved it.
        let behind = clockSeconds - stallBeforeSeconds - polledSeconds
        // The first poll measured may already be behind, as after a resume, by no more than a
        // poll's noise: a renderer held at where it started for longer is buffering, and the
        // track's end would come early if that were taken as its lag.
        let lag = min(lagSeconds ?? min(behind, Self.behindToleranceSeconds), behind)
        lagSeconds = lag
        // Past the end by the clock, a renderer that's behind is stuck at the end, and waiting
        // on it would never end the track.
        guard behind - lag > Self.behindToleranceSeconds,
            clockSeconds - stallSeconds < durationSeconds
        else {
            behindPolls = 0
            return
        }
        behindPolls += 1
        guard behindPolls >= Self.stalledPolls else { return }
        stallSeconds = min(
            Self.stallCapSeconds, max(stallSeconds, stallBeforeSeconds + behind - lag))
    }
}
