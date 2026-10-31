/// The ID3v1 genre list, which ID3v2 `TCON` "(17)" references and MP4 `gnre` (index + 1) use.
/// Only the genres the generator picks from.
private let id3v1Genres: [String: Int] = [
    "Blues": 0, "Country": 2, "Hip-Hop": 7, "Jazz": 8, "Metal": 9, "Pop": 13, "Reggae": 16,
    "Rock": 17, "Soundtrack": 24, "Ambient": 26, "Classical": 32, "Electronic": 52, "Folk": 80,
]

/// The genres in the generated library: the ID3v1 ones, plus some it doesn't have.
let fixtureGenres = id3v1Genres.keys.sorted() + ["Shoegaze", "Post-Rock", "Kayōkyoku"]

func id3v1GenreIndex(_ genre: String) -> Int? { id3v1Genres[genre] }
