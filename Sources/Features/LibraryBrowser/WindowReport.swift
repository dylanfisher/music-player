import Foundation

/// What `MusicPlayer --measure-window` prints as one JSON line and Bench reads (ADR 0014).
public struct WindowReport: Codable, Equatable, Sendable {
    /// From the kernel starting the process to the table's first rows drawn.
    public var launchSeconds: Double
    /// Physical footprint when the first rows were drawn.
    public var loadedMB: Double
    /// Physical footprint after scrolling through every row with each album's art decoded.
    public var scrolledMB: Double
    public var rows: Int
    public var artImages: Int
    public var artFailures: Int

    public init(
        launchSeconds: Double, loadedMB: Double, scrolledMB: Double, rows: Int, artImages: Int,
        artFailures: Int
    ) {
        self.launchSeconds = launchSeconds
        self.loadedMB = loadedMB
        self.scrolledMB = scrolledMB
        self.rows = rows
        self.artImages = artImages
        self.artFailures = artFailures
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case launchSeconds, loadedMB, scrolledMB, rows, artImages, artFailures
    }

    /// Decodes one report, rejecting a key it doesn't know, so a renamed field fails instead of
    /// reading as missing.
    public static func decode(_ data: Data) throws -> WindowReport {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let known = Set(CodingKeys.allCases.map(\.rawValue))
        if let unknown = object.keys.sorted().first(where: { !known.contains($0) }) {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: [], debugDescription: "unknown key \(unknown)"))
        }
        return try JSONDecoder().decode(WindowReport.self, from: data)
    }
}
