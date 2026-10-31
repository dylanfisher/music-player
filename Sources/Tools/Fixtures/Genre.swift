import Metadata

/// The genres in the generated library: ID3v1 genres by index, which ID3v2 and MP4 can store as
/// references, and one that isn't on the list.
let fixtureGenres =
    [26, 0, 32, 2, 52, 80, 7, 8, 9, 13, 16, 17, 24, 178, 176].map { id3v1Genres[$0] } + [
        "Kayōkyoku"
    ]

func id3v1GenreIndex(_ genre: String) -> Int? { id3v1Genres.firstIndex(of: genre) }
