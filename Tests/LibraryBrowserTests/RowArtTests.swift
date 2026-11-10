import Artwork
import Foundation
import Metadata
import Testing

@testable import Fixtures
@testable import LibraryBrowser

/// Reads that wait until the test lets them go, counting how many wait at once.
private final class HeldReads: @unchecked Sendable {
    private let lock = NSLock()
    private let released = DispatchSemaphore(value: 0)
    private var waiting = 0
    private(set) var mostAtOnce = 0
    private(set) var paths: [String] = []
    private(set) var queues: Set<String> = []

    func read(_ art: EmbeddedArt, path: String) throws -> Data {
        let queue = String(cString: __dispatch_queue_get_label(nil))
        lock.withLock {
            waiting += 1
            mostAtOnce = max(mostAtOnce, waiting)
            paths.append(path)
            queues.insert(queue)
        }
        released.wait()
        lock.withLock { waiting -= 1 }
        return Data()
    }

    var count: Int { lock.withLock { paths.count } }

    func releaseAll(_ count: Int) {
        for _ in 0..<count { released.signal() }
    }
}

@MainActor @Test func artLoadsSeveralAtOnceOffTheCooperativePoolAndEachOnce() async throws {
    let reads = HeldReads()
    let rowArt = RowArt(pixels: 64, read: reads.read, thumbnails: nil)
    let stamp = FileStamp(sizeBytes: 1, modifiedSeconds: 0)
    let art = EmbeddedArt(offset: 0, byteCount: 1, mimeType: "image/png", unsynchronised: false)
    let requested = filesReadAtOnce + 2
    let keys = (0..<requested).map { ArtworkKey(path: "/m/\($0).flac", art: art) }
    var wantedReads = 0
    rowArt.wanted = {
        wantedReads += 1
        return Set(keys)
    }
    for track in 0..<requested {
        #expect(rowArt.image(art, path: "/m/\(track).flac", stamp: stamp) == nil)
        // Asked again while it loads, as a redraw does.
        #expect(rowArt.image(art, path: "/m/\(track).flac", stamp: stamp) == nil)
    }
    let deadline = Date().addingTimeInterval(waitLimit)
    while reads.count < filesReadAtOnce, Date() < deadline {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(reads.count == filesReadAtOnce, "only \(reads.count) reads started")
    reads.releaseAll(requested)
    // Empty bytes don't decode, so each load ends as a failure.
    func settled() -> Int {
        (0..<requested).filter {
            rowArt.hasFailed(keys[$0])
        }.count
    }
    while settled() < requested, Date() < deadline {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(settled() == requested, "\(settled()) of \(requested) loads ended")
    #expect(reads.mostAtOnce == filesReadAtOnce)
    #expect(Set(reads.paths).count == reads.paths.count, "a path was read twice: \(reads.paths)")
    #expect(reads.queues == ["ArtworkLoader"])
    // Once a pass, not once a request: a pass per request asked for and per load ended at most.
    #expect(wantedReads <= 2 * requested, "the rows on screen were read \(wantedReads) times")
}
