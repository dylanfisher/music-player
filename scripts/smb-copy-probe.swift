// Finds out whether this Mac copies a file on an SMB share without the bytes crossing the
// network, as SMB's server-side copy (FSCTL_SRV_COPYCHUNK) would (ADR 0108, part 47.7). The
// owner runs it on a scratch folder on the NAS, the one tool AGENTS.md lets touch it; no agent
// or test runs it.
//
//   swift scripts/smb-copy-probe.swift <scratch folder on the share> [<megabytes>]
//
// It makes a new folder inside the scratch folder and writes only there: one file of random
// bytes (256 MB unless <megabytes> says), then a copy of it made each way macOS offers:
// clonefile(2), copyfile(3) with COPYFILE_CLONE_FORCE, copyfile(3) with COPYFILE_DATA, and a
// plain read and write. It times each copy, counts the bytes this Mac's network interfaces
// moved meanwhile, and checks the copy against the original by SHA-256, read back uncached.
// A copy the server makes moves next to nothing. At the end it removes its folder, with
// everything it wrote there. Paste back what it prints.
import CommonCrypto
import Darwin
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("smb-copy-probe: \(message)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard (2...3).contains(arguments.count) else {
    fail("usage: smb-copy-probe.swift <scratch folder on the share> [<megabytes>]")
}
let scratch = URL(fileURLWithPath: arguments[1], isDirectory: true).standardizedFileURL.path
let megabytes = arguments.count == 3 ? Int(arguments[2]) ?? 0 : 256
guard megabytes > 0 else { fail("<megabytes> must be a whole number above 0") }
let fileBytes = megabytes * 1024 * 1024
let chunkBytes = 8 * 1024 * 1024

var isFolder: ObjCBool = false
guard FileManager.default.fileExists(atPath: scratch, isDirectory: &isFolder), isFolder.boolValue
else { fail("\(scratch) isn't a folder") }

var volume = statfs()
guard statfs(scratch, &volume) == 0 else { fail("can't stat the volume of \(scratch)") }
func text<T>(_ field: T) -> String {
    withUnsafeBytes(of: field) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
}
let fileSystem = text(volume.f_fstypename)
print("volume: \(text(volume.f_mntfromname)) on \(text(volume.f_mntonname)), \(fileSystem)")
if fileSystem != "smbfs" {
    print("note: not an SMB share, so what follows says nothing about the NAS")
}

let folder = scratch + "/music-player-copy-probe-" + UUID().uuidString
guard mkdir(folder, 0o700) == 0 else {
    fail("can't make \(folder): \(String(cString: strerror(errno)))")
}
// Only the names this script writes, so the cleanup can't remove anything else.
let original = folder + "/original.bin"
let copies = ["clonefile", "copyfile-clone", "copyfile-data", "read-write"].map {
    folder + "/" + $0 + ".bin"
}
func cleanUp() {
    for path in [original] + copies { unlink(path) }
    rmdir(folder)
}

/// The bytes every network interface but loopback has sent and received, which wrap at 4 GB
/// each, so `moved(since:)` subtracts per interface.
func interfaceBytes() -> [String: (sent: UInt32, received: UInt32)] {
    var first: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&first) == 0 else { fail("can't read the network interfaces") }
    defer { freeifaddrs(first) }
    var counts: [String: (sent: UInt32, received: UInt32)] = [:]
    var next = first
    while let address = next {
        defer { next = address.pointee.ifa_next }
        guard let socket = address.pointee.ifa_addr, socket.pointee.sa_family == AF_LINK,
            address.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
            let data = address.pointee.ifa_data
        else { continue }
        let stats = data.assumingMemoryBound(to: if_data.self).pointee
        counts[String(cString: address.pointee.ifa_name)] = (stats.ifi_obytes, stats.ifi_ibytes)
    }
    return counts
}

func moved(since before: [String: (sent: UInt32, received: UInt32)]) -> Int {
    interfaceBytes().reduce(0) { total, entry in
        guard let start = before[entry.key] else { return total }
        return total + Int(entry.value.sent &- start.sent)
            + Int(entry.value.received &- start.received)
    }
}

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

func megabytesText(_ bytes: Int) -> String { String(format: "%.1f MB", Double(bytes) / 1_048_576) }

/// Writes `fileBytes` of random bytes to `original`, flushed, and returns their SHA-256.
func writeOriginal() -> [UInt8] {
    let descriptor = open(original, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    guard descriptor >= 0 else { fail("can't create \(original)") }
    defer { close(descriptor) }
    var context = CC_SHA256_CTX()
    CC_SHA256_Init(&context)
    var chunk = [UInt8](repeating: 0, count: chunkBytes)
    var written = 0
    while written < fileBytes {
        let count = min(chunkBytes, fileBytes - written)
        chunk.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, count) }
        chunk.withUnsafeBytes { _ = CC_SHA256_Update(&context, $0.baseAddress, CC_LONG(count)) }
        guard chunk.withUnsafeBytes({ write(descriptor, $0.baseAddress, count) }) == count else {
            fail("can't write \(original): \(String(cString: strerror(errno)))")
        }
        written += count
    }
    guard fsync(descriptor) == 0 else { fail("can't flush \(original)") }
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    CC_SHA256_Final(&digest, &context)
    return digest
}

/// The SHA-256 of the file at `path`, read without caching, so the share answers.
func hash(_ path: String) -> [UInt8]? {
    let descriptor = open(path, O_RDONLY)
    guard descriptor >= 0 else { return nil }
    defer { close(descriptor) }
    _ = fcntl(descriptor, F_NOCACHE, 1)
    var context = CC_SHA256_CTX()
    CC_SHA256_Init(&context)
    var chunk = [UInt8](repeating: 0, count: chunkBytes)
    while true {
        let count = chunk.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, chunkBytes) }
        guard count >= 0 else { return nil }
        if count == 0 { break }
        chunk.withUnsafeBytes { _ = CC_SHA256_Update(&context, $0.baseAddress, CC_LONG(count)) }
    }
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    CC_SHA256_Final(&digest, &context)
    return digest
}

/// Copies `original` to `copy` with plain reads and writes, as the writer's temp file does.
func readWrite(to copy: String) -> Int32 {
    let source = open(original, O_RDONLY)
    let destination = open(copy, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    defer {
        close(source)
        close(destination)
    }
    guard source >= 0, destination >= 0 else { return -1 }
    _ = fcntl(source, F_NOCACHE, 1)
    var chunk = [UInt8](repeating: 0, count: chunkBytes)
    while true {
        let count = chunk.withUnsafeMutableBytes { read(source, $0.baseAddress, chunkBytes) }
        guard count >= 0 else { return -1 }
        if count == 0 { break }
        guard chunk.withUnsafeBytes({ write(destination, $0.baseAddress, count) }) == count else {
            return -1
        }
    }
    return fsync(destination)
}

print("writing \(megabytesText(fileBytes)) of random bytes to \(original)")
let writeStart = now()
let writeTraffic = interfaceBytes()
let expected = writeOriginal()
let writeSeconds = now() - writeStart
print(
    String(
        format: "  %.2f s, %@ over the network", writeSeconds,
        megabytesText(moved(since: writeTraffic))))

let methods: [(name: String, copy: (String) -> Int32)] = [
    ("clonefile", { clonefile(original, $0, 0) }),
    (
        "copyfile COPYFILE_CLONE_FORCE",
        { copyfile(original, $0, nil, copyfile_flags_t(COPYFILE_CLONE_FORCE)) }
    ),
    ("copyfile COPYFILE_DATA", { copyfile(original, $0, nil, copyfile_flags_t(COPYFILE_DATA)) }),
    ("read and write", readWrite),
]
var serverSide: [String] = []
for ((name, copy), path) in zip(methods, copies) {
    let traffic = interfaceBytes()
    let start = now()
    let result = copy(path)
    let failure = result == 0 ? nil : String(cString: strerror(errno))
    let seconds = now() - start
    let bytes = moved(since: traffic)
    guard failure == nil else {
        print("\(name): failed: \(failure!)")
        unlink(path)
        continue
    }
    let same = hash(path) == expected
    print(
        String(
            format: "%@: %.2f s, %@ over the network, %@", name, seconds, megabytesText(bytes),
            same ? "the copy matches" : "THE COPY DOESN'T MATCH"))
    if same, bytes < fileBytes / 10 { serverSide.append(name) }
    unlink(path)
}

cleanUp()
guard fileSystem == "smbfs" else {
    print("verdict: not an SMB share; run it on a scratch folder on the NAS")
    exit(0)
}
print(
    serverSide.isEmpty
        ? "verdict: no server-side copy; every copy that worked crossed the network"
        : "verdict: server-side copy through \(serverSide.joined(separator: ", "))")
