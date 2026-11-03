import Artwork
import CoreGraphics
import Foundation
import Log
import Metadata

private let logger = moduleLogger()

/// One row's art to load.
struct ArtRequest: Equatable {
    var key: ArtworkKey
    var art: EmbeddedArt
    var stamp: FileStamp
}

/// Art the table asked for and hasn't loaded yet, newest first. Scrolling asks for every row it
/// passes, so the queue keeps at most `capacity` requests and loads only those still on screen.
struct ArtRequests {
    static let capacity = 200
    /// Oldest first.
    private(set) var waiting: [ArtRequest] = []

    /// Adds `request`, or moves it to the front if it's already waiting.
    mutating func add(_ request: ArtRequest) {
        waiting.removeAll { $0.key == request.key }
        waiting.append(request)
        if waiting.count > Self.capacity { waiting.removeFirst(waiting.count - Self.capacity) }
    }

    /// The newest request still `wanted`, dropping those that aren't.
    mutating func next(wanted: Set<ArtworkKey>) -> ArtRequest? {
        waiting.removeAll { !wanted.contains($0.key) }
        return waiting.popLast()
    }
}

/// Loads the Album Art column's images off the main thread, `filesReadAtOnce` at a time, through an
/// `ArtworkLoader` whose images are the size the column draws, and hands each to `loaded` on the
/// main thread. Art that fails to load is logged once and not asked for again.
@MainActor
final class RowArt {
    /// Images kept, at up to 4 MB each at the largest size: one per album on a few screens.
    static let cachedImages = 40
    /// The largest image loaded, sharp in a column up to 512 points wide.
    static let largestPixels = 1024
    /// Failed art remembered, so a broken file isn't read on every redraw, and the most of them
    /// logged.
    static let rememberedFailures = 1000
    static let loggedFailures = 100

    let loader: ArtworkLoader
    private var requests = ArtRequests()
    /// The art being read.
    private var loading: Set<ArtworkKey> = []
    private var failed: Set<ArtworkKey> = []
    /// The art the rows on screen show.
    var wanted: () -> Set<ArtworkKey> = { [] }
    var loaded: (ArtworkKey, CGImage) -> Void = { _, _ in }

    /// Images at most `pixels` on their longer side, read by `read` and kept in `thumbnails`.
    init(pixels: Int, read: @escaping ArtRead, thumbnails: ThumbnailStore?) {
        loader = ArtworkLoader(
            maxPixelSize: pixels, capacity: Self.cachedImages, read: read, thumbnails: thumbnails)
    }

    /// The pixels art needs to be sharp on a retina screen in a column `width` points wide,
    /// rounded up to a power of two so resizing the column seldom changes it.
    static func pixels(columnWidth width: CGFloat) -> Int {
        var pixels = 64
        while pixels < Int((width * 2).rounded(.up)), pixels < largestPixels { pixels *= 2 }
        return pixels
    }

    /// Whether the art `key` names failed to load, so it isn't asked for again.
    func hasFailed(_ key: ArtworkKey) -> Bool { failed.contains(key) }

    /// The cached image, or nil after asking for it to be loaded from the file `stamp`
    /// describes.
    func image(_ art: EmbeddedArt, path: String, stamp: FileStamp) -> CGImage? {
        let key = ArtworkKey(path: path, art: art)
        if let image = loader.cached(key) { return image }
        guard !failed.contains(key), !loading.contains(key) else { return nil }
        requests.add(ArtRequest(key: key, art: art, stamp: stamp))
        loadNext()
        return nil
    }

    private func loadNext() {
        guard loading.count < filesReadAtOnce, !requests.waiting.isEmpty else { return }
        // Read once a pass: it reads the rows on screen.
        let wanted = wanted()
        while loading.count < filesReadAtOnce, let request = requests.next(wanted: wanted) {
            load(request)
        }
    }

    private func load(_ request: ArtRequest) {
        loading.insert(request.key)
        Task {
            let result = await loader.load(
                request.art, path: request.key.path, stamp: request.stamp)
            loading.remove(request.key)
            switch result {
            case .success(let image): loaded(request.key, image)
            case .failure(let error):
                if failed.count < Self.loggedFailures { logger.error("\(error)") }
                if failed.count >= Self.rememberedFailures { failed = [] }
                failed.insert(request.key)
            }
            loadNext()
        }
    }
}
