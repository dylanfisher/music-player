import Foundation
import Testing

@testable import Log

@Test func aBusyGapOverTheThresholdIsAStall() {
    var clock = StallClock(thresholdNanos: 100)
    #expect(clock.mark(asleep: false, at: 1000) == nil)
    #expect(clock.mark(asleep: false, at: 1050) == nil)
    let stall = clock.mark(asleep: true, at: 1200)
    #expect(stall?.0 == 1050 && stall?.1 == 1200)
}

@Test func sleepingIsNotAStall() {
    var clock = StallClock(thresholdNanos: 100)
    _ = clock.mark(asleep: true, at: 1000)
    #expect(clock.mark(asleep: false, at: 9000) == nil)
    #expect(clock.mark(asleep: true, at: 9050) == nil)
}

@Test func spansOverlappingAStallIncludeOpenAndEndedOnes() {
    let log = IntervalLog()
    let before = log.begin(.query, at: 10)
    log.end(before, at: 20)
    let during = log.begin(.pageFetch, at: 30)
    log.end(during, at: 60)
    _ = log.begin(.artLoad, at: 50)
    let after = log.begin(.refresh, at: 200)
    log.end(after, at: 210)
    #expect(
        log.spans(from: 25, to: 100) == [
            IntervalSpan(interval: .pageFetch, start: 30, end: 60),
            IntervalSpan(interval: .artLoad, start: 50, end: nil),
        ])
}

@Test func theEndedRingKeepsTheNewest() {
    let log = IntervalLog()
    for start in 0..<UInt64(IntervalLog.endedKept + 5) {
        log.end(log.begin(.query, at: start * 10), at: start * 10 + 1)
    }
    let spans = log.spans(from: 0, to: .max)
    #expect(spans.count == IntervalLog.endedKept)
    #expect(spans.first?.start == 50)
    #expect(spans.map(\.start) == spans.map(\.start).sorted())
}

@Test func aPendingIntervalEndsOnceAndASecondBeginReplacesTheFirst() {
    let pending = PendingInterval(.playToFirstSample)
    pending.end()
    #expect(!pending.isOpen)
    pending.begin()
    pending.begin()
    #expect(pending.isOpen)
    pending.end()
    #expect(!pending.isOpen)
    pending.end()
}

@Test func aCancelledIntervalRecordsNoTime() {
    let before = DispatchTime.now().uptimeNanoseconds
    let pending = PendingInterval(.scanBatch)
    pending.begin()
    pending.begin()
    pending.cancel()
    pending.cancel()
    #expect(!pending.isOpen)
    let spans = IntervalLog.shared.spans(from: before, to: .max).filter { $0.interval == .scanBatch }
    #expect(spans.isEmpty)
}

@Test func aStallNamesWhatRan() {
    let stall = Stall(
        milliseconds: 230.4, intervals: [(.pageFetch, 180), (.query, 41.6)],
        lastCommand: "playback.play", event: "keyDown")
    #expect(
        stall.description
            == "main thread stalled 230 ms; ran: page fetch 180 ms, query 42 ms;"
            + " last command: playback.play; event: keyDown")
    #expect(
        Stall(milliseconds: 101, intervals: [], lastCommand: nil, event: nil).description
            == "main thread stalled 101 ms; ran: no marked interval")
}

/// The main run loop blocked inside a query is logged once, naming the query and the command.
@MainActor
@Test func blockingTheMainRunLoopIsReported() {
    var stalls: [Stall] = []
    let detector = StallDetector(event: { "keyDown" }, report: { stalls.append($0) })
    detector.start()
    detector.noteCommand("edit.find")
    CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
        signposted(.query) { Thread.sleep(forTimeInterval: 0.15) }
    }
    CFRunLoopWakeUp(CFRunLoopGetMain())
    let deadline = Date(timeIntervalSinceNow: 2)
    while stalls.isEmpty, Date() < deadline {
        _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
    }
    #expect(stalls.count == 1, "saw \(stalls.map(\.description))")
    let stall = stalls.first
    #expect((stall?.milliseconds ?? 0) >= 150)
    #expect(stall?.intervals.map(\.0).contains(.query) == true)
    #expect(stall?.lastCommand == "edit.find")
    #expect(stall?.event == "keyDown")
}
