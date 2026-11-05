import Foundation
import Testing

@testable import MusicPlayer
@testable import Settings

/// A saver over a fresh config file whose scheduled writes wait in `due` until a test runs
/// them, on a clock the test sets, reading `point` and counting the reads.
@MainActor
private final class Stand {
    let settings: ConfigStore<AppSettings>
    let saver: ResumeSaver
    var point = ResumePoint(track: "music/library/A/01.flac", seconds: 1)
    var reads = 0
    var writes = 0
    var clock = Date(timeIntervalSince1970: 1_000)
    var due: [(seconds: Double, work: @MainActor () -> Void)] = []

    init() throws {
        settings = ConfigStore(
            AppSettings(),
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("resume-saver-\(UUID().uuidString)/config.json"),
            check: { _, _, _ in nil }, creating: true)
        weak var owner: Stand?
        saver = ResumeSaver(settings) {
            owner?.reads += 1
            return owner?.point
        }
        owner = self
        settings.changed = { [unowned self] keys in
            if keys.contains(AppSettings().resume.key) { writes += 1 }
        }
        saver.now = { [unowned self] in clock }
        saver.runAfter = { [unowned self] seconds, work in due.append((seconds, work)) }
    }

    /// Runs the writes scheduled so far, after their wait.
    func runDue() async {
        let ready = due
        due = []
        for (seconds, work) in ready {
            clock += seconds
            work()
        }
        // Each runs its save in a task.
        for _ in 0..<10 { await Task.yield() }
    }
}

@MainActor @Test func manyChangesWriteTheConfigOnceWithTheLatestState() async throws {
    let stand = try Stand()
    for second in 1...100 {
        stand.point.seconds = Double(second)
        stand.saver.changed()
    }
    #expect(stand.due.count == 1)
    #expect(stand.due.first?.seconds == ResumeSaver.delaySeconds)
    await stand.runDue()
    #expect(stand.reads == 1)
    #expect(stand.writes == 1)
    #expect(stand.settings[\.resume].seconds == 100)
}

@MainActor @Test func aChangeSoonAfterAWriteWaitsOutTheInterval() async throws {
    let stand = try Stand()
    stand.saver.changed()
    await stand.runDue()
    stand.point.seconds = 2
    stand.saver.changed()
    #expect(stand.due.first?.seconds == ResumeSaver.intervalSeconds)
    await stand.runDue()
    #expect(stand.writes == 2)
    // Well after the last write, a change waits the delay alone.
    stand.clock += 60
    stand.point.seconds = 3
    stand.saver.changed()
    #expect(stand.due.first?.seconds == ResumeSaver.delaySeconds)
}

@MainActor @Test func anUnchangedStateIsntWrittenAndQuittingWritesAtOnce() async throws {
    let stand = try Stand()
    await stand.saver.save()
    #expect(stand.writes == 1)
    await stand.saver.save()
    #expect(stand.reads == 2)
    #expect(stand.writes == 1)
    stand.point.selected = "music/library/A/02.flac"
    await stand.saver.save()
    #expect(stand.writes == 2)
    #expect(stand.settings[\.resume] == stand.point)
}
