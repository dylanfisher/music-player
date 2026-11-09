import Foundation
import ImageIO
import Metadata
import TagWriter

/// Which files Get Artwork gives the release's cover (ADR 0172).
public enum CoverFill: Sendable {
    /// Files with no art, or art of fewer pixels than the cover.
    case fillMissing
    /// Every file.
    case replace
}

/// One album's files that carry the same Discogs release id, which Get Artwork covers.
public struct CoverAlbum: Equatable, Sendable {
    /// How the problems name the album.
    public var title: String
    public var releaseID: Int
    public var paths: [String]

    public init(title: String, releaseID: Int, paths: [String]) {
        self.title = title
        self.releaseID = releaseID
        self.paths = paths
    }
}

/// What Get Artwork writes: each file's front cover, how many albums get one, and why the
/// others don't.
public struct CoverPlan: Sendable {
    public var edits: [(path: String, edit: TagEdit)] = []
    public var albums = 0
    public var problems: [String] = []
}

/// Works out Get Artwork's edits for `albums`: each release's cover through `cover`, once a
/// release, and for Fill Missing each file's art as `pixels` reads it, which runs on the
/// caller's thread. The cover replaces only the front cover, so a file's other pictures stay.
public func coverPlan(
    _ albums: [CoverAlbum], fill: CoverFill,
    cover: (Int) async -> Result<Cover, CoverProblem>,
    pixels: (String) throws -> Int?
) async -> CoverPlan {
    var plan = CoverPlan()
    var covers: [Int: Result<Cover, CoverProblem>] = [:]
    for album in albums {
        let result: Result<Cover, CoverProblem>
        if let known = covers[album.releaseID] {
            result = known
        } else {
            result = await cover(album.releaseID)
            covers[album.releaseID] = result
        }
        let image: Cover
        switch result {
        case .success(let fetched): image = fetched
        case .failure(let problem):
            plan.problems.append("\(album.title): no cover: \(problem)")
            continue
        }
        var covered = false
        for path in album.paths {
            if fill == .fillMissing {
                do {
                    if let held = try pixels(path), held >= image.width * image.height {
                        continue
                    }
                } catch {
                    plan.problems.append("\(path): its art couldn't be read: \(error)")
                    continue
                }
            }
            plan.edits.append(
                (path, TagEdit(art: .replace(image.bytes, mimeType: image.mimeType))))
            covered = true
        }
        if covered { plan.albums += 1 }
    }
    return plan
}

/// The pixels, width times height, of the art the file at `path` shows; nil for none. Reads
/// the file, so it runs off the main thread.
public func artPixels(at path: String) throws -> Int? {
    let url = URL(fileURLWithPath: path, isDirectory: false)
    guard let art = try readMetadata(at: url).metadata.art else { return nil }
    let data = try readArt(art, at: url)
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
        let width = properties[kCGImagePropertyPixelWidth] as? Int,
        let height = properties[kCGImagePropertyPixelHeight] as? Int
    else {
        // Art that doesn't decode is no better than none.
        return 0
    }
    return width * height
}
