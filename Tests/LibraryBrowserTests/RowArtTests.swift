import Artwork
import Foundation
import Metadata
import Testing

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
    let rowArt = RowArt(pixels: 64, read: reads.read)
    rowArt.isWanted = { _ in true }
    let art = EmbeddedArt(offset: 0, byteCount: 1, mimeType: "image/png", unsynchronised: false)
    let requested = RowArt.loadsAtOnce + 2
    for track in 0..<requested {
        #expect(rowArt.image(art, path: "/m/\(track).flac") == nil)
        // Asked again while it loads, as a redraw does.
        #expect(rowArt.image(art, path: "/m/\(track).flac") == nil)
    }
    let deadline = Date().addingTimeInterval(10)
    while reads.count < RowArt.loadsAtOnce, Date() < deadline {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(reads.count == RowArt.loadsAtOnce, "only \(reads.count) reads started")
    reads.releaseAll(requested)
    // Empty bytes don't decode, so each load ends as a failure.
    func settled() -> Int {
        (0..<requested).filter {
            rowArt.hasFailed(ArtworkKey(path: "/m/\($0).flac", offset: art.offset))
        }.count
    }
    while settled() < requested, Date() < deadline {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(settled() == requested, "\(settled()) of \(requested) loads ended")
    #expect(reads.mostAtOnce == RowArt.loadsAtOnce)
    #expect(Set(reads.paths).count == reads.paths.count, "a path was read twice: \(reads.paths)")
    #expect(reads.queues == ["ArtworkLoader"])
}
