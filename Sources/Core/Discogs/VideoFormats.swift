/// Discogs's formats of discs and tapes that hold video, which "Skip Blu-ray, DVD and video"
/// leaves out of the candidates, as YATE's `DiscogsIgnoredMedia` does (ADR 0132).
let videoFormats: Set<String> = [
    "Blu-ray", "Blu-ray-R", "HD DVD", "HD DVD-R", "DVD", "DVDr", "UMD", "VHS", "Betamax",
    "Video 2000", "Video8", "MiniDV", "U-matic", "Laserdisc", "CED", "VHD", "VCD", "SVCD",
]

extension CatalogRelease {
    /// Whether every format of the release holds video. A CD with a bonus DVD isn't: its CD may
    /// be what the files are. Nor is a release with no format.
    var isVideo: Bool {
        !formats.isEmpty && formats.allSatisfy { videoFormats.contains($0.name) }
    }
}
