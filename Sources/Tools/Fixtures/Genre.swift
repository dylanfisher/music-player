import Metadata

/// The genres in the generated library: ID3v1 genres, which ID3v2 and MP4 can store as
/// references, and one that isn't on the list.
let fixtureGenres = [
    "Ambient", "Blues", "Classical", "Country", "Electronic", "Folk", "Hip-Hop", "Jazz", "Metal",
    "Pop", "Reggae", "Rock", "Soundtrack", "Shoegaze", "Post-Rock", "Kayōkyoku",
]

func id3v1GenreIndex(_ genre: String) -> Int? { id3v1Genres.firstIndex(of: genre) }
