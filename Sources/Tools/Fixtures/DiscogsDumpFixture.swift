import CommonCrypto
import Foundation
import Library
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

extension DiscogsDumpFixture {
    /// A library album a shaped dump is made for: its artist, title and tracks as the library
    /// has them.
    public struct Album: Sendable {
        public var artist: String?
        public var title: String
        public var tracks: [(title: String, seconds: Double)]

        public init(artist: String?, title: String, tracks: [(title: String, seconds: Double)]) {
            self.artist = artist
            self.title = title
            self.tracks = tracks
        }
    }

    /// What `writeShapedSet` wrote.
    public struct Shaped: Sendable {
        public var masters: Int
        public var releases: Int
        /// The albums, by their index in the albums given, whose master is titled otherwise,
        /// so only a search by their artist alone finds it (ADR 0174).
        public var artistOnly: Set<Int>
    }

    /// The artist Discogs credits a compilation to, as the matcher searches for it.
    static let various = "Various"

    /// Writes a dump set shaped as the 2026-11-01 dump is where it matters to the matcher
    /// (phase 73): each of `albums` is one master of 20 to 100 releases, most near 20 and a
    /// few near 100, as a popular album's are. The releases of a master share its tracklist
    /// with the differences pressings have: a second of difference, a bonus track, a track
    /// fewer, a few seconds' difference throughout, remastered titles; and they differ in
    /// country, year and format, as the tie-break reads them. About one album in fourteen with
    /// an artist has its master under another title, so only an artist-only search finds it.
    /// "Various Artists" albums are credited to Discogs's "Various".
    public static func writeShapedSet(date: String, albums: [Album], in folder: URL) throws
        -> Shaped
    {
        var masters = ""
        var releases = ""
        var artistIDs: [String: Int] = [:]
        var artistOnly: Set<Int> = []
        var releaseID = 0
        for (index, album) in albums.enumerated() {
            // An album with no artist is a compilation's.
            let artist = album.artist.map { $0 == variousArtists ? various : $0 } ?? various
            let artistID = artistIDs[artist] ?? artistIDs.count + 1
            artistIDs[artist] = artistID
            let credit =
                "<artists><artist><id>\(artistID)</id><name>\(escaped(artist))</name></artist>"
                + "</artists>"
            let hidden = artist != various && index % 14 == 5
            if hidden { artistOnly.insert(index) }
            let title = hidden ? "Untitled Sessions \(index)" : album.title
            let master = index + 1
            // 20 to 100, mostly near 20: a square of an even spread.
            let spread = index * 7919 % 81
            let count = 20 + spread * spread / 80
            masters +=
                "<master id=\"\(master)\"><main_release>\(releaseID + 1)</main_release>\(credit)"
                + "<title>\(escaped(title))</title><year>\(1990 + index % 30)</year></master>\n"
            for variant in 0..<count {
                releaseID += 1
                releases += shapedRelease(
                    id: releaseID, master: master, isMain: variant == 0, credit: credit,
                    title: title, tracks: album.tracks, variant: variant)
            }
        }
        try writeSet(date: date, masters: masters, releases: releases, in: folder)
        return Shaped(masters: albums.count, releases: releaseID, artistOnly: artistOnly)
    }

    /// One release of a shaped master, its `variant` choosing how it differs from the album.
    private static func shapedRelease(
        id: Int, master: Int, isMain: Bool, credit: String, title: String,
        tracks: [(title: String, seconds: Double)], variant: Int
    ) -> String {
        var listed = tracks
        switch variant % 6 {
        case 1: listed = listed.map { ($0.title, $0.seconds + 1) }
        case 2: listed.append(("Bonus Track", 200))
        case 3 where listed.count > 1: listed.removeLast()
        case 4: listed = listed.map { ($0.title, $0.seconds + 7) }
        case 5: listed = listed.map { ($0.title + " (Remastered)", $0.seconds) }
        default: break
        }
        let countries = ["UK", "US", "Germany", "Japan", "Europe", "France"]
        let format = ["CD", "Vinyl", "File"][variant % 3]
        var xml =
            "<release id=\"\(id)\">\(credit)<title>\(escaped(title))</title><labels>"
            + "<label name=\"Label \(master % 211)\" catno=\"SHP \(id)\" id=\"\(master % 211)\"/>"
            + "</labels><extraartists><artist><id>5\(id % 100)</id><name>Engineer \(id % 100)"
            + "</name><role>Mastered By</role></artist></extraartists><formats>"
            + "<format name=\"\(format)\" qty=\"1\" text=\"\"><descriptions><description>Album"
            + "</description></descriptions></format></formats><genres><genre>Rock</genre>"
            + "</genres><country>\(countries[variant % countries.count])</country>"
            + "<released>\(1990 + variant % 30)</released>"
            + "<master_id is_main_release=\"\(isMain)\">\(master)</master_id><tracklist>"
        for (number, track) in listed.enumerated() {
            let seconds = Int(track.seconds.rounded())
            let duration = "\(seconds / 60):" + String(format: "%02d", seconds % 60)
            xml +=
                "<track><position>\(number + 1)</position><title>\(escaped(track.title))</title>"
                + "<duration>\(duration)</duration></track>"
        }
        return xml
            + "</tracklist><identifiers><identifier type=\"Barcode\" value=\"5 012 \(id)\"/>"
            + "</identifiers></release>\n"
    }

    /// `text` for XML text or an attribute: each character markup could take as a character
    /// reference.
    private static func escaped(_ text: String) -> String {
        text.unicodeScalars.map { scalar in
            "&<>\"".unicodeScalars.contains(scalar) ? "&#\(scalar.value);" : String(scalar)
        }.joined()
    }
}
