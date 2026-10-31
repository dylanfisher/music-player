import AVFoundation
import CommonCrypto
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What AVFoundation reads from a file's common metadata: a second reader that shares no code
/// with ours.
struct AVTags: Equatable {
    var title: String?
    var artist: String?
    var album: String?
    var artwork: Data?

    /// The synchronous properties work on macOS 12; the async `load` calls need 13.
    init(_ url: URL) {
        let items = AVURLAsset(url: url).commonMetadata
        func value(_ key: AVMetadataKey) -> AVMetadataItem? { items.first { $0.commonKey == key } }
        title = value(.commonKeyTitle)?.stringValue
        artist = value(.commonKeyArtist)?.stringValue
        album = value(.commonKeyAlbumName)?.stringValue
        artwork = value(.commonKeyArtwork)?.dataValue
    }
}

/// The lines of `afinfo` that describe the audio: format, duration, bytes and packets, without
/// the file name or where the audio starts, which an edit may move.
func audioDescription(_ url: URL) throws -> [String] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/afinfo")
    process.arguments = [url.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CorpusError(
            "afinfo failed on \(url.path): \(String(decoding: output, as: UTF8.self))")
    }
    let kept = ["Data format", "estimated duration", "audio bytes", "audio packets", "bit rate"]
    return String(decoding: output, as: UTF8.self).split(separator: "\n").map(String.init)
        .filter { line in kept.contains { line.hasPrefix($0) } }
}

/// Whether two files are the same byte for byte, by `cmp`.
func sameBytes(_ a: URL, _ b: URL) throws -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/cmp")
    process.arguments = ["-s", a.path, b.path]
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus == 0
}

/// SHA-256 of `ranges` of the file at `url`, in order. Reads into one buffer with `pread`, so
/// a long run over gigabytes allocates nothing per read.
func sha256(_ url: URL, ranges: [Range<Int>]) throws -> [UInt8] {
    let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else { throw CorpusError("can't open \(url.path)") }
    defer { close(descriptor) }
    var context = CC_SHA256_CTX()
    CC_SHA256_Init(&context)
    var buffer = [UInt8](repeating: 0, count: 8 * 1024 * 1024)
    for range in ranges {
        var offset = range.lowerBound
        while offset < range.upperBound {
            let want = min(buffer.count, range.upperBound - offset)
            let count = buffer.withUnsafeMutableBytes {
                pread(descriptor, $0.baseAddress, want, off_t(offset))
            }
            guard count > 0 else { throw CorpusError("can't read \(url.path) at \(offset)") }
            buffer.withUnsafeBytes {
                _ = CC_SHA256_Update(&context, $0.baseAddress, CC_LONG(count))
            }
            offset += count
        }
    }
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    CC_SHA256_Final(&digest, &context)
    return digest
}

/// The file's mode, flags, owner, creation date and extended attributes (Finder tags among
/// them), which an edit must keep.
func fileAttributes(_ url: URL) throws -> [String] {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { throw CorpusError("can't stat \(url.path)") }
    let names = url.withUnsafeFileSystemRepresentation { path -> [String] in
        let length = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard length > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: length)
        listxattr(path, &buffer, length, XATTR_NOFOLLOW)
        return String(decoding: buffer.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            .split(separator: "\0").map(String.init).sorted()
    }
    let xattrs = try names.map { name -> String in
        let length = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard length >= 0 else { throw CorpusError("can't read \(name) of \(url.path)") }
        var value = [UInt8](repeating: 0, count: length)
        getxattr(url.path, name, &value, length, 0, XATTR_NOFOLLOW)
        return "\(name) \(Data(value).base64EncodedString())"
    }
    return [
        "mode \(String(info.st_mode, radix: 8))", "flags \(info.st_flags)",
        "owner \(info.st_uid):\(info.st_gid)",
        "created \(info.st_birthtimespec.tv_sec).\(info.st_birthtimespec.tv_nsec)",
    ] + xattrs
}

/// A JPEG of random pixels, `side` pixels square, so it doesn't compress much.
func noiseJPEG(side: Int) throws -> Data {
    var generator = SystemRandomNumberGenerator()
    var pixels = (0..<side * side * 4).map { _ in UInt8.random(in: 0...255, using: &generator) }
    let image = pixels.withUnsafeMutableBytes { raw -> CGImage? in
        CGContext(
            data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
    }
    let data = NSMutableData()
    guard let image,
        let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil)
    else { throw CorpusError("can't make a \(side)-pixel JPEG") }
    CGImageDestinationAddImage(
        destination, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        throw CorpusError("can't encode a \(side)-pixel JPEG")
    }
    return data as Data
}
