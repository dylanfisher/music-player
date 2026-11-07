/// The custom keys YATE's Discogs Wizard writes that the library index stores (ADR 0129). The
/// rest of its keys are read from the file when needed.
public enum DiscogsKey {
    /// The release's number, as "1234567".
    public static let releaseID = "DISCOGS_RELEASE_ID"
    /// The master's number with an "m" before it, as "m744074".
    public static let masterID = "DISCOGS_MASTER_ID"
}
