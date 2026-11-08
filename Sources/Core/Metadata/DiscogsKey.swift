/// The custom keys YATE's Discogs Wizard writes that the library index stores (ADRs 0129, 0131). The
/// rest of its keys are read from the file when needed.
public enum DiscogsKey {
    /// The release's number, as "1234567".
    public static let releaseID = "DISCOGS_RELEASE_ID"
    /// The master's number with an "m" before it, as "m744074".
    public static let masterID = "DISCOGS_MASTER_ID"
    /// The release's country as YATE writes it: its own key in FLAC, then in MP4 and ID3, then
    /// the `COUNTRY` it writes beside them in every format (ADR 0128). The first one a file has
    /// is its country.
    public static let releaseCountry = [
        "DISCOGS_ALBUM_RELEASECOUNTRY", "DISCOGS ALBUM RELEASE COUNTRY", "COUNTRY",
    ]
}
