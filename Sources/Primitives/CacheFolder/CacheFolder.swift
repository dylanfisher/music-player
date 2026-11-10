import Foundation

/// Files kept between launches in one folder, each named by a 128-bit hash of its key: a cache,
/// whose owner makes a file again when it's missing. The least recently used go first once the
/// folder holds more than `capacityBytes` or `capacityFiles`; a trim runs after each
/// `trimEveryBytes` written. A file that can't be read, written or removed is handed to
/// `report`, up to `reportedFailures` a session. Safe to use from any thread.
public final class CacheFolder: @unchecked Sendable {
    /// The most failures reported a session.
    static let reportedFailures = 20

    public let directory: URL
    /// What a file holds, singular, as the failures name it: "thumbnail".
    let noun: String
    let capacityBytes: Int
    let capacityFiles: Int
    let trimEveryBytes: Int
    private let report: @Sendable (String) -> Void
    private let lock = NSLock()
    // Guarded by `lock`.
    private var writtenSinceTrim = 0
    private var trimming = false
    private var failures = 0

    public init(
        directory: URL, noun: String, capacityBytes: Int, capacityFiles: Int = .max,
        trimEveryBytes: Int, report: @escaping @Sendable (String) -> Void
    ) {
        self.directory = directory
        self.noun = noun
        self.capacityBytes = capacityBytes
        self.capacityFiles = capacityFiles
        self.trimEveryBytes = trimEveryBytes
        self.report = report
    }

    /// The bytes stored under `key`, marked recently used; nil when there are none.
    public func data(_ key: [String]) -> Data? {
        let url = fileURL(key)
        let bytes: Data
        do {
            bytes = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            fail("can't read the stored \(noun) \(url.path): \(error)")
            return nil
        }
        do {
            try FileManager.default.setAttributes(
                [.modificationDate: Date()], ofItemAtPath: url.path)
        } catch {
            fail("can't mark the stored \(noun) \(url.path) used: \(error)")
        }
        return bytes
    }

    /// Stores `data` under `key`; `of` names what it was made from, for a failure.
    public func store(_ data: Data, _ key: [String], of source: String) {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL(key), options: .atomic)
        } catch {
            return fail("can't store the \(noun) of \(source): \(error)")
        }
        let due = lock.withLock {
            writtenSinceTrim += data.count
            return writtenSinceTrim >= trimEveryBytes
        }
        if due { trimInBackground() }
    }

    /// Removes the file under `key`, reporting why: "doesn't decode; removing it" unless
    /// `problem` says otherwise.
    public func discard(_ key: [String], because problem: String = "doesn't decode") {
        let url = fileURL(key)
        fail("the stored \(noun) \(url.path) \(problem); removing it")
        remove(url)
    }

    /// Removes the least recently used files until the folder is within its capacity, on a
    /// utility queue. Does nothing while a trim is under way.
    public func trimInBackground() {
        let start = lock.withLock {
            guard !trimming else { return false }
            trimming = true
            writtenSinceTrim = 0
            return true
        }
        guard start else { return }
        DispatchQueue.global(qos: .utility).async {
            self.trim()
            self.lock.withLock { self.trimming = false }
        }
    }

    /// `trimInBackground`'s work, on the calling thread.
    public func trim() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let files: [(url: URL, bytes: Int, used: Date)]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
            ).map { url in
                let values = try url.resourceValues(forKeys: Set(keys))
                return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
            }
        } catch CocoaError.fileReadNoSuchFile {
            return
        } catch {
            return fail("can't list the stored \(noun)s in \(directory.path): \(error)")
        }
        var bytes = files.reduce(0) { $0 + $1.bytes }
        var count = files.count
        for file in files.sorted(by: { $0.used < $1.used }) {
            guard bytes > capacityBytes || count > capacityFiles else { break }
            remove(file.url)
            bytes -= file.bytes
            count -= 1
        }
    }

    /// The file for `key`, named by a 128-bit hash of its parts.
    public func fileURL(_ key: [String]) -> URL {
        let bytes = Array(key.joined(separator: "\u{0}").utf8)
        let hash = fnv1a(bytes, basis: 0xcbf2_9ce4_8422_2325)
        let second = fnv1a(bytes, basis: 0x8422_2325_cbf2_9ce4)
        return directory.appendingPathComponent(
            String(format: "%016llx%016llx", hash, second), isDirectory: false)
    }

    /// Reports `message`, unless the session has reported `reportedFailures` already.
    public func fail(_ message: String) {
        let send = lock.withLock {
            failures += 1
            return failures <= Self.reportedFailures
        }
        if send { report(message) }
    }

    private func remove(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            // Another trim got there first.
        } catch {
            fail("can't remove the stored \(noun) \(url.path): \(error)")
        }
    }
}

/// FNV-1a over `bytes` from `basis`.
private func fnv1a(_ bytes: [UInt8], basis: UInt64) -> UInt64 {
    bytes.reduce(basis) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
}
