/// Which files a download takes (the service's `docs/api.md`, Format policies).
enum FormatPolicy: String, Equatable, Sendable, Codable, CaseIterable {
    /// FLAC files. The default.
    case flac
    /// FLAC or ALAC.
    case lossless
    /// MP3 at 320 kbps constant, or variable averaging 220–270 kbps (V0).
    case mp3320 = "mp3_320"
    /// Any audio format.
    case any
}
