import Darwin
import Fixtures
import Foundation
import Library
import Log
import Metadata

/// The longest input the fuzzer makes or keeps. Generated files are under 64 KB; a tag-corpus
/// file is cut to this, which keeps its tags when they come first.
let maximumInputBytes = 256 * 1024
/// The most seeds a target starts from, spread over the files it could use.
let maximumSeeds = 300

/// `~/Library/Caches/MusicPlayer/fuzz`: the generated library that seeds the parsers, and each
/// target's work folder.
func fuzzCaches() throws -> URL {
    try FileManager.default.url(
        for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false
    ).appendingPathComponent(appDirectoryName).appendingPathComponent("fuzz")
}

/// The generated library, made on first use under a lock, since every target's run may start at
/// once.
func fixtureLibrary() throws -> URL {
    let caches = try fuzzCaches()
    try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
    let root = caches.appendingPathComponent("fixture-library")
    let lockPath = caches.appendingPathComponent("fixture-library-lock").path
    let lock = open(lockPath, O_RDWR | O_CREAT, 0o644)
    guard lock >= 0, flock(lock, LOCK_EX) == 0 else {
        throw FuzzError(
            "can't lock \(lockPath): \(String(cString: strerror(errno)))")
    }
    defer { close(lock) }
    _ = try generateFixtures(count: coveringLibraryFileCount, in: root)
    return root
}

/// Every regular file under `root` with an extension the scanner reads, sorted by path.
func audioFiles(in root: URL) -> [URL] {
    let enumerator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.isRegularFileKey])
    return (enumerator?.allObjects as? [URL] ?? [])
        .filter { audioFileExtensions.contains($0.pathExtension.lowercased()) }
        .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        .sorted { $0.path < $1.path }
}

/// Up to `maximumInputBytes` from the start of the file.
func head(of url: URL) throws -> [UInt8] {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    return [UInt8](try handle.read(upToCount: maximumInputBytes) ?? Data())
}

/// The starts of the audio files under `roots` in one of the target's formats, by content.
func seedFiles(for target: FuzzTarget, in roots: [URL]) throws -> [[UInt8]] {
    guard !target.seedFormats.isEmpty else { return [] }
    return try roots.flatMap(audioFiles).map(head).filter { bytes in
        do throws(ParseFailure) {
            return target.seedFormats.contains(try FileFormat(ByteReader(MemorySource(bytes))))
        } catch {
            return false
        }
    }
}

/// The inputs a target starts from: its generated files, the tag-corpus clones in `clones`, and
/// the seeds it makes. Over `maximumSeeds`, every nth is kept, so each format and layout stays.
@MainActor func seedInputs(for target: FuzzTarget, clones: URL?, work: URL) throws -> [[UInt8]] {
    let library = try fixtureLibrary()
    var inputs = try seedFiles(for: target, in: [library] + (clones.map { [$0] } ?? []))
        .flatMap(target.seedInputs)
    inputs += try target.madeSeeds(work, library)
    var seen = Set<[UInt8]>()
    inputs = inputs.filter { seen.insert($0).inserted }
    guard inputs.count > maximumSeeds else { return inputs }
    let stride = Double(inputs.count) / Double(maximumSeeds)
    return (0..<maximumSeeds).map { inputs[Int(Double($0) * stride)] }
}

/// The most tokens taken from the seeds.
let maximumTokens = 128

/// IDs and keys that recur in the inputs, most frequent first: runs of four letters, digits,
/// spaces or "©", the shape of atom, chunk and frame IDs, and quoted JSON strings up to 40 bytes.
func harvestTokens(_ inputs: [[UInt8]]) -> [[UInt8]] {
    func isIDByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
            UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: " "), 0xA9:
            true
        default: false
        }
    }
    let quote = UInt8(ascii: "\"")
    var counts: [[UInt8]: Int] = [:]
    for input in inputs {
        let bytes = input.prefix(64 * 1024)
        var index = bytes.startIndex
        while index < bytes.endIndex {
            if index + 4 <= bytes.endIndex, bytes[index..<index + 4].allSatisfy(isIDByte) {
                counts[Array(bytes[index..<index + 4]), default: 0] += 1
            }
            if bytes[index] == quote,
                let end = bytes[(index + 1)..<min(index + 41, bytes.endIndex)].firstIndex(of: quote)
            {
                counts[Array(bytes[index...end]), default: 0] += 1
            }
            index += 1
        }
    }
    return counts.filter { $0.value >= 2 }
        .sorted {
            $0.value != $1.value ? $0.value > $1.value : $0.key.lexicographicallyPrecedes($1.key)
        }
        .prefix(maximumTokens).map(\.key)
}

/// A file name for an input: its FNV-1a hash.
func inputName(_ bytes: [UInt8]) -> String {
    var hash: UInt64 = 0xCBF2_9CE4_8422_2325
    for byte in bytes { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01B3 }
    return String(format: "%016llx", hash)
}
