/// The custom keys YATE's Discogs Wizard writes, as the survey found them spelled (ADR 0128).
/// The index stores the release and master ids and the country (ADRs 0129, 0131); the mapping
/// writes the rest (ADR 0132). Some are spelled one way in FLAC and in title case with spaces
/// in MP4 and ID3, which `…Titled` names.
public enum DiscogsKey {
    /// The release's number, as "1234567".
    public static let releaseID = "DISCOGS_RELEASE_ID"
    /// The master's number with an "m" before it, as "m744074".
    public static let masterID = "DISCOGS_MASTER_ID"
    /// The first label's catalog number, as "Label: catno".
    public static let catalogNumber = "DISCOGS_CATALOG_NUMBER"
    /// FLAC's spelling of the other labels' catalog numbers, before their "-2", "-3".
    public static let furtherCatalogNumberVorbis = "DISCOGS CATALOG NUMBER"
    /// The artists' names on Discogs, `valueSeparator` between them.
    public static let artistList = "DISCOGS_ARTIST_LIST"
    /// "canonical=ANV" for each artist the release credits by another name.
    public static let nameVariationList = "DISCOGS_ANV_LIST"
    public static let ordinalPosition = "DISCOGS_RELEASE_ORDINAL_POSITION"
    public static let ordinalPositionTitled = "Discogs Release Ordinal Position"
    /// The track's position as Discogs writes it: "A1", "2", "CD2-4".
    public static let trackNumberText = "TRACK_NUMBER_TEXT"
    public static let trackNumberTextTitled = "Track Number Text"
    public static let releaseCountryVorbis = "DISCOGS_ALBUM_RELEASECOUNTRY"
    public static let releaseCountryTitled = "Discogs Album Release Country"
    /// The country again, which Roon reads.
    public static let country = "COUNTRY"
    public static let releaseURL = "DISCOGS_RELEASE_URL"
    public static let masterURL = "DISCOGS_MASTER_URL"
    public static let artistURL = "DISCOGS_ARTIST_URL"
    public static let albumArtistURL = "DISCOGS_ALBUMARTIST_URL"
    /// The album artist URL key as early builds of this app spelled it, which a file they
    /// tagged may still hold and a replace removes (ADR 0152).
    public static let albumArtistURLUnderscored = "DISCOGS_ALBUM_ARTIST_URL"
    public static let labelURL = "DISCOGS_LABEL_URL"
    public static let producer = "PRODUCER"
    /// The credits no other key takes.
    public static let involvedPeople = "INVOLVEDPEOPLE"
    /// What YATE puts between the values of a list held as one value.
    public static let valueSeparator = ";;;"

    /// The release's country as YATE writes it: its own key in FLAC, then in MP4 and ID3, then
    /// the `COUNTRY` it writes beside them in every format, uppercased as keys are read. The
    /// first one a file has is its country.
    public static let releaseCountry = [
        releaseCountryVorbis, releaseCountryTitled.uppercased(), country,
    ]
}
