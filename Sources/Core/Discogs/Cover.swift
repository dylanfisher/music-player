import Artwork
import Foundation
import ImageIO
import Metadata

/// A release's primary image from Discogs, checked, as the tagger writes it to an album's
/// files (ADR 0140).
public struct Cover: Equatable, Sendable {
    public var bytes: Data
    /// JPEG or PNG, from the bytes' signature, never from the server's `Content-Type`.
    public var mimeType: String
    public var width: Int
    public var height: Int

    /// "600 × 600 JPEG".
    public var text: String {
        "\(width) × \(height) \(mimeType == pngMIMEType ? "PNG" : "JPEG")"
    }
}

/// Why an album gets no cover. Its tags still apply.
public enum CoverProblem: Error, Equatable, Sendable, CustomStringConvertible {
    /// Discogs serves images only to a request with a token.
    case needsToken
    /// The release lists no image, or none on Discogs's image host.
    case noImage
    case notAnImage
    /// It doesn't decode, or ends before its format's end marker.
    case damaged
    case tooLarge(width: Int, height: Int)
    case fetch(DiscogsAPIError)

    /// Whether asking again would give the same answer: the release or its image is what it
    /// is. A token added, the network back or the rate limit passed can change the others.
    public var isLasting: Bool {
        switch self {
        case .noImage, .notAnImage, .damaged, .tooLarge: true
        case .needsToken, .fetch: false
        }
    }

    public var description: String {
        switch self {
        case .needsToken: "covers need a Discogs token in config.json"
        case .noImage: "Discogs has no image for the release"
        case .notAnImage: "the image is neither a JPEG nor a PNG"
        case .damaged: "the image is damaged or cut short"
        case .tooLarge(let width, let height):
            "the image is \(width) × \(height), more than \(Cover.largestSide) pixels a side"
        case .fetch(let error): "\(error)"
        }
    }

    /// "Persuader – Stockholm: no cover: …", as an album's problem line says it.
    public func line(for album: String) -> String { "\(album): no cover: \(self)" }
}

extension Cover {
    /// The longest side a cover may have, in pixels: Discogs's own images are at most 600, and
    /// a scan for print is about 3,000.
    static let largestSide = 8_000
    /// The most bytes an image may have.
    static let byteCap = 10 * 1024 * 1024

    private static let jpegStart: [UInt8] = [0xFF, 0xD8, 0xFF]
    private static let jpegEnd: [UInt8] = [0xFF, 0xD9]
    /// The most padding bytes a JPEG may have after its end marker.
    private static let jpegPadding = 16
    private static let pngStart: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    /// The IEND chunk: its type and its CRC.
    private static let pngEnd: [UInt8] = [0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82]

    /// `bytes` as a cover, when they are a whole JPEG or PNG that decodes through the one decode
    /// of art (ADR 0025 row 4) and is at most `largestSide` a side.
    init(checking bytes: [UInt8]) throws(CoverProblem) {
        let mimeType: String
        if bytes.starts(with: Self.jpegStart) {
            // Some encoders pad a JPEG past its end marker with zero or FF bytes.
            let padding = bytes.suffix(Self.jpegPadding).reversed().prefix {
                $0 == 0 || $0 == 0xFF
            }
            let content = bytes.dropLast(padding.count)
            guard content.suffix(Self.jpegEnd.count).elementsEqual(Self.jpegEnd) else {
                throw .damaged
            }
            mimeType = jpegMIMEType
        } else if bytes.starts(with: Self.pngStart) {
            guard bytes.suffix(Self.pngEnd.count).elementsEqual(Self.pngEnd) else {
                throw .damaged
            }
            mimeType = pngMIMEType
        } else {
            throw .notAnImage
        }
        let data = Data(bytes)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { throw .damaged }
        guard max(width, height) <= Self.largestSide else {
            throw .tooLarge(width: width, height: height)
        }
        guard thumbnail(of: data, maxPixelSize: 64) != nil else { throw .damaged }
        self.init(bytes: data, mimeType: mimeType, width: width, height: height)
    }
}

extension DiscogsAPI {
    /// The release's primary image as a cover: the release through the cache, then its image
    /// from `covers` or, paced as every request is, from Discogs, kept in `covers` once it
    /// passes (ADR 0189). Without a token nothing is asked. The image is checked and decoded off
    /// the actor, so a large one doesn't hold up the next request's turn.
    public nonisolated func cover(release id: Int) async throws(CoverProblem) -> Cover {
        guard hasToken else { throw .needsToken }
        let fetched: FetchedRelease
        do {
            fetched = try await release(id: id)
        } catch {
            throw .fetch(error)
        }
        guard let url = fetched.primaryImage else { throw .noImage }
        let covers = covers
        if let kept = await blockingFileWork({ covers.cover(from: url) }) { return kept }
        let bytes: [UInt8]
        do {
            bytes = try await image(at: url)
        } catch {
            throw .fetch(error)
        }
        let cover = try Cover(checking: bytes)
        await blockingFileWork { covers.store(cover, from: url) }
        return cover
    }
}
