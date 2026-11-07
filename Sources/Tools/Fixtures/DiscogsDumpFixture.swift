import CommonCrypto
import Foundation
import zlib

/// Discogs dump files for tests and the bench, in the dumps' format: gzipped XML named
/// `discogs_<date>_<kind>.xml.gz`, and `discogs_<date>_CHECKSUM.txt` with each one's SHA-256.
public enum DiscogsDumpFixture {
    /// The dumps' kinds, as their file names have them.
    static let kinds = ["labels", "artists", "masters", "releases"]

    static func fileName(date: String, kind: String) -> String {
        "discogs_\(date)_\(kind).xml.gz"
    }

    static func checksumFileName(date: String) -> String {
        "discogs_\(date)_CHECKSUM.txt"
    }

    /// Writes a complete set: each kind's records inside its root element, gzipped, and the
    /// checksum file listing all four.
    public static func writeSet(
        date: String, labels: String = "", artists: String = "", masters: String = "",
        releases: String, in folder: URL
    ) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (kind, records) in zip(kinds, [labels, artists, masters, releases]) {
            try writeGzip(
                Data("<\(kind)>\n\(records)</\(kind)>\n".utf8),
                to: folder.appendingPathComponent(fileName(date: date, kind: kind)))
        }
        try writeChecksums(date: date, in: folder)
    }

    /// Writes the checksum file for the set's files in `folder` as they are now.
    static func writeChecksums(date: String, in folder: URL) throws {
        let lines = try kinds.map { kind in
            let name = fileName(date: date, kind: kind)
            return "\(try sha256(of: folder.appendingPathComponent(name))) \(name)\n"
        }
        try Data(lines.joined().utf8).write(
            to: folder.appendingPathComponent(checksumFileName(date: date)))
    }

    /// `data` gzipped into the file at `url`.
    static func writeGzip(_ data: Data, to url: URL) throws {
        var stream = z_stream()
        // 15 + 16: the largest window, with gzip's header and trailer.
        guard
            deflateInit2_(
                &stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY,
                ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
        else { throw CocoaError(.fileWriteUnknown) }
        defer { deflateEnd(&stream) }
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        var input = [UInt8](data)
        let count = input.count
        try input.withUnsafeMutableBufferPointer { source in
            stream.next_in = source.baseAddress
            stream.avail_in = UInt32(count)
            var result = Z_OK
            while result != Z_STREAM_END {
                result = buffer.withUnsafeMutableBufferPointer { out in
                    stream.next_out = out.baseAddress
                    stream.avail_out = UInt32(out.count)
                    return deflate(&stream, Z_FINISH)
                }
                guard result == Z_OK || result == Z_STREAM_END else {
                    throw CocoaError(.fileWriteUnknown)
                }
                output.append(contentsOf: buffer[0..<(buffer.count - Int(stream.avail_out))])
            }
        }
        try output.write(to: url)
    }

    private static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest) }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// `count` releases as the dump has them, each with two artists, two labels, a format,
    /// barcodes, credits and ten tracks with their own artists, for the bench: about the
    /// size of an average release in the 2026-11-01 dump without its videos and notes. Every
    /// fourth release has no master.
    public static func syntheticReleases(count: Int) -> String {
        var xml = ""
        xml.reserveCapacity(count * 3000)
        for id in 1...max(count, 1) {
            let master =
                id % 4 == 0
                ? "" : #"<master_id is_main_release="\#(id % 3 == 0)">\#(id / 2 + 1)</master_id>"#
            xml +=
                #"<release id="\#(id)"><artists><artist><id>\#(id % 997)</id><name>Artist \#(id % 997)</name><join>&amp;</join></artist><artist><id>\#(id % 991 + 1000)</id><name>Other Artist (2)</name><anv>Other</anv></artist></artists>"#
            xml +=
                #"<title>Album Number \#(id) (Remastered)</title><labels><label name="Label \#(id % 211)" catno="LBL \#(id)" id="\#(id % 211)"/><label name="Distributor" catno="none" id="9"/></labels>"#
            xml +=
                #"<extraartists><artist><id>5\#(id % 100)</id><name>Engineer \#(id % 100)</name><role>Mastered By</role></artist><artist><id>6\#(id % 50)</id><name>Writer \#(id % 50)</name><role>Written-By [All Tracks By]</role><tracks>A1 to B5</tracks></artist></extraartists>"#
            xml +=
                #"<formats><format name="CD" qty="1" text=""><descriptions><description>Album</description><description>Remastered</description></descriptions></format></formats>"#
            xml +=
                #"<genres><genre>Electronic</genre></genres><styles><style>Techno</style><style>Ambient</style></styles><country>Germany</country><released>2001-03-00</released>"#
            xml +=
                #"<notes>Recorded somewhere, mastered elsewhere.</notes><data_quality>Correct</data_quality>\#(master)<tracklist>"#
            for track in 1...10 {
                xml +=
                    #"<track><position>\#(track)</position><title>Track Title \#(track) of \#(id)</title><duration>\#(3 + track % 5):\#(10 + track)</duration><artists><artist><id>\#(id % 997)</id><name>Artist \#(id % 997)</name></artist></artists></track>"#
            }
            xml +=
                #"</tracklist><identifiers><identifier type="Barcode" description="Text" value="4 006 \#(100_000 + id) 2"/><identifier type="Matrix / Runout" description="" value="LBL \#(id) A"/></identifiers>"#
            xml +=
                #"<videos><video src="https://www.youtube.com/watch?v=x\#(id)" duration="300" embed="true"><title>A video</title><description>About the video.</description></video></videos></release>"#
            xml += "\n"
        }
        return xml
    }
}
