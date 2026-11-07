import Foundation

/// A `CatalogWriter` on a thread of its own, so a dump's records are parsed while the ones
/// before them are encoded and inserted (ADR 0130). Records go over in batches, a transaction
/// each, and at most `batchesInFlight` wait at once, so memory stays flat however fast the
/// parser runs ahead.
final class BackgroundCatalogWriter: @unchecked Sendable {
    /// Records a transaction holds: enough that a commit costs nothing next to its inserts,
    /// few enough that the batches waiting hold a few tens of MB.
    static let recordsPerBatch = 2000
    static let batchesInFlight = 2

    // `writer` is used only on `queue`; `pending` only on the thread that adds records;
    // `failure` only under `lock`.
    private let writer: CatalogWriter
    private let queue = DispatchQueue(label: "Discogs.CatalogWriter", qos: .utility)
    private let slots = DispatchSemaphore(value: BackgroundCatalogWriter.batchesInFlight)
    private let lock = NSLock()
    private var failure: (any Error)?
    private var pending: [DumpRecord] = []

    init(creatingAt url: URL) throws {
        writer = try CatalogWriter(creatingAt: url)
        pending.reserveCapacity(Self.recordsPerBatch)
    }

    /// Adds `record`, sending a batch once it's full. Throws the writer's error once a batch
    /// has failed, so the parse stops there.
    func add(_ record: DumpRecord) throws {
        try throwFailure()
        pending.append(record)
        if pending.count == Self.recordsPerBatch { send() }
    }

    /// Writes what's left, waits for every batch, then builds the indexes and notes the dump.
    func finish(dumpDate: String) throws {
        send()
        try queue.sync {
            try throwFailure()
            try writer.finish(dumpDate: dumpDate)
        }
    }

    /// Waits for every batch sent to be written or to fail, so the writer is done with the
    /// file. Call it before removing a failed catalog.
    func stop() {
        pending = []
        queue.sync {}
    }

    private func send() {
        guard !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        slots.wait()
        queue.async { [self] in
            defer { slots.signal() }
            guard currentFailure == nil else { return }
            do {
                try writer.write(batch)
            } catch {
                lock.lock()
                failure = error
                lock.unlock()
            }
        }
    }

    private var currentFailure: (any Error)? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }

    private func throwFailure() throws {
        if let failure = currentFailure { throw failure }
    }
}
