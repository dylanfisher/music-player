import AppKit
import Artwork
import Library
import Metadata

/// Scrolls the track table as a trackpad does, from the middle of the list, and times each
/// frame, for `--measure-scroll` (ADR 0073). A timer moves the rows once a frame; a run-loop
/// observer adds up the time the main thread waits, so a frame's busy time is the rest of it:
/// the scroll, the drawing, and whatever else ran on the main thread, such as art arriving or a
/// refresh. After the last frame it moves a screenful down, as Page Down does, and times until
/// that screen's art shows.
@MainActor
final class ScrollMeasurement {
    /// A display's frame.
    static let frameSeconds = 1.0 / 60
    /// Frames scrolled: ten seconds' worth.
    static let frames = 600
    /// A flick's first step, which each frame's step then shrinks by `flickDecay`, until a step
    /// under a point starts the next flick. About a hundred rows a flick.
    static let flickPoints: CGFloat = 80
    static let flickDecay: CGFloat = 0.95
    /// The longest the art on screen may take to arrive after the last frame.
    static let coverTimeoutSeconds = 30.0

    /// What a run measured, in milliseconds.
    struct Result {
        /// Each frame's busy time.
        var framesMs: [Double]
        /// The busy time of each frame a refresh landed in.
        var refreshFramesMs: [Double]
        /// From the page down until its art showed; nil after `coverTimeoutSeconds`.
        var lastCoverMs: Double?
    }

    private let table: TrackTableController
    private let intervalNanos: UInt64
    private let everyInterval: () -> Void
    private var timer: Timer?
    private var observers: [CFRunLoopObserver] = []
    private var waitStarted: UInt64 = 0
    private var waited: UInt64 = 0
    private var lastTick: UInt64?
    private var framesMs: [Double] = []
    /// The frames a refresh landed in, by index into `framesMs`.
    private var refreshFrames: Set<Int> = []
    private var step = flickPoints
    private var lastInterval: UInt64 = 0
    private var pagedDownAt: UInt64?
    private var finished: ((Double?) -> Void)?

    /// `everyInterval` runs every `intervalSeconds` while the rows scroll.
    init(
        table: TrackTableController, intervalSeconds: Double,
        everyInterval: @escaping () -> Void
    ) {
        self.table = table
        intervalNanos = UInt64(intervalSeconds * 1e9)
        self.everyInterval = everyInterval
    }

    /// Notes that a refresh landed in the frame under way.
    func refreshed() {
        guard pagedDownAt == nil else { return }
        refreshFrames.insert(framesMs.count)
    }

    /// Scrolls `frames` frames, then pages down and waits for the art on screen.
    func run() async -> Result {
        // The top of the list holds the files without tags, and no art.
        table.scroll(toRow: table.table.numberOfRows / 2)
        observeWaiting()
        defer { stopObserving() }
        let lastCoverMs = await withCheckedContinuation { continuation in
            finished = { continuation.resume(returning: $0) }
            let timer = Timer(timeInterval: Self.frameSeconds, repeats: true) { _ in
                MainActor.assumeIsolated { self.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        return Result(
            framesMs: framesMs,
            refreshFramesMs: refreshFrames.sorted().filter(framesMs.indices.contains).map {
                framesMs[$0]
            }, lastCoverMs: lastCoverMs)
    }

    private func tick() {
        let now = DispatchTime.now().uptimeNanoseconds
        defer {
            lastTick = now
            waited = 0
        }
        if let pagedDownAt {
            let sinceMs = Double(now - pagedDownAt) / 1e6
            let waiting = table.rowsAwaitingArt()
            guard waiting == 0 || sinceMs > Self.coverTimeoutSeconds * 1000 else { return }
            timer?.invalidate()
            finished?(waiting == 0 ? sinceMs : nil)
            finished = nil
            return
        }
        if let lastTick {
            framesMs.append(Double(now - lastTick - min(waited, now - lastTick)) / 1e6)
        }
        if now - lastInterval >= intervalNanos {
            lastInterval = now
            everyInterval()
        }
        guard framesMs.count < Self.frames, table.scrollFrame(by: step) else {
            table.pageDown()
            pagedDownAt = DispatchTime.now().uptimeNanoseconds
            return
        }
        step = step * Self.flickDecay < 1 ? Self.flickPoints : step * Self.flickDecay
    }

    /// Adds up the main thread's waits: the last observer before it sleeps notes the time, and
    /// the first after it wakes adds what passed.
    private func observeWaiting() {
        let before = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max
        ) { _, _ in
            MainActor.assumeIsolated { self.waitStarted = DispatchTime.now().uptimeNanoseconds }
        }
        let after = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min
        ) { _, _ in
            MainActor.assumeIsolated {
                self.waited += DispatchTime.now().uptimeNanoseconds - self.waitStarted
            }
        }
        observers = [before, after].compactMap { $0 }
        for observer in observers {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
    }

    private func stopObserving() {
        for observer in observers {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
        observers = []
    }
}

/// Counts art reads and adds a delay to each, as a NAS's latency.
final class SlowArtReads: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    private let delaySeconds: Double

    init(delaySeconds: Double) {
        self.delaySeconds = delaySeconds
    }

    var count: Int { lock.withLock { reads } }

    func read(_ art: EmbeddedArt, path: String) throws -> Data {
        lock.withLock { reads += 1 }
        if delaySeconds > 0 { Thread.sleep(forTimeInterval: delaySeconds) }
        return try readArtBytes(art, path: path)
    }
}
