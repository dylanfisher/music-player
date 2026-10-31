import Foundation

/// One file the generator will write.
struct PlannedFile: Sendable {
    var path: String
    var seed: SeedKind
    /// Nil for an untagged file.
    var tags: FixtureTags?
    var art: Int?
    var layout: TagLayout
    var malformation: Malformation?
}

/// Which tag blocks a file gets, and how they're written.
enum TagLayout: Sendable {
    case vorbis(VorbisStyle)
    case mp4(genreAsIndex: Bool)
    /// MP3 and AIFF.
    case id3(ID3Style)
    /// A `LIST/INFO` chunk, an `id3 ` chunk, or both.
    case wav(info: Bool, id3: ID3Style?)
}

/// The seed that malformed files of each kind are made from.
extension Malformation {
    var seed: SeedKind {
        switch self {
        case .truncated, .garbage, .flacBlockPastEnd, .vorbisCommentPastBlock,
            .unreadableTrackNumber:
            .flac16
        case .empty, .id3TagPastEnd, .id3FramePastTag: .mp3
        case .mp4AtomTooSmall, .mp4AtomPastParent: .alac16
        case .riffChunkPastEnd: .wav16
        }
    }
}

/// Lays out `count` files as artists, albums and discs. The same count always gives the same
/// plan, so a rerun can tell whether the files on disk are current.
func planLibrary(count: Int) -> [PlannedFile] {
    var random = SplitMix64(seed: 0x4D50_4649_5854_5552)
    let perKind = max(1, count / 10_000)
    // At least one valid file, so there's an album directory to put the broken ones in.
    let broken = Array(
        Malformation.allCases.flatMap { Array(repeating: $0, count: perKind) }.prefix(count - 1))
    let validCount = count - broken.count

    var files: [PlannedFile] = []
    var albumDirectories: [String] = []
    var usedDirectories: Set<String> = []
    var artists: [String] = []
    while files.count < validCount {
        let artist = artistName(&random)
        artists.append(artist)
        for _ in 0..<random.pick(weighted: [(1, 35), (2, 30), (3, 20), (4, 10), (6, 5)]) {
            guard files.count < validCount else { break }
            let compilation = artists.count > 10 && random.chance(0.05)
            let album = albumTitle(&random)
            let year = Int.random(in: 1960...2025, using: &random)
            var directory =
                (compilation ? "Compilations" : fileName(artist)) + "/\(fileName(album)) (\(year))"
            while usedDirectories.contains(directory) { directory += " +" }
            usedDirectories.insert(directory)
            albumDirectories.append(directory)
            files += planAlbum(
                album, in: directory, artist: compilation ? nil : artist, year: year,
                trackArtists: artists, limit: validCount - files.count, &random)
        }
    }

    for (index, malformation) in broken.enumerated() {
        let directory = random.pick(albumDirectories)
        let title = trackTitle(&random)
        files.append(
            PlannedFile(
                path:
                    "\(directory)/\(90 + index) \(fileName(title)).\(malformation.seed.fileExtension)",
                seed: malformation.seed,
                tags: FixtureTags(
                    title: title, artist: "Broken",
                    // Something for the damage to land on.
                    trackNumber: malformation == .unreadableTrackNumber ? 1 : nil,
                    compilation: false),
                art: nil, layout: brokenLayout(malformation), malformation: malformation))
    }
    return files
}

private func brokenLayout(_ malformation: Malformation) -> TagLayout {
    let id3 = ID3Style(version: .v23, preferUTF16: false, genreAsReference: false, paddingBytes: 0)
    switch malformation.seed {
    case .flac16:
        return .vorbis(
            VorbisStyle(lowercaseKeys: false, combinedTrackNumber: false, paddingBytes: 0))
    case .alac16: return .mp4(genreAsIndex: false)
    case .wav16: return .wav(info: true, id3: nil)
    default: return .id3(id3)
    }
}

/// A Various Artists album when `artist` is nil, with each track by one of `trackArtists`.
private func planAlbum(
    _ album: String, in directory: String, artist: String?, year: Int, trackArtists: [String],
    limit: Int, _ random: inout SplitMix64
) -> [PlannedFile] {
    let month = Int.random(in: 1...12, using: &random)
    let day = Int.random(in: 1...28, using: &random)
    let fullDate = String(format: "%d-%02d-%02d", year, month, day)
    let date: String? = random.pick(weighted: [("\(year)", 60), (fullDate, 30), (nil, 10)])
    let genre = random.chance(0.9) ? random.pick(fixtureGenres) : nil
    let discs = random.chance(0.08) ? Int.random(in: 2...3, using: &random) : 1
    let discFolders = discs > 1 && random.chance(0.5)
    let trackRange = random.pick(weighted: [(3...6, 15), (8...14, 70), (15...24, 15)])
    let tracksPerDisc = Int.random(in: trackRange, using: &random)
    let albumSeed = random.pick(weighted: [
        (SeedKind.flac16, 30), (.flac24x96, 8), (.flac24x192, 3), (.alac16, 8), (.alac24x96, 3),
        (.aac, 12), (.mp3, 22), (.wav16, 4), (.wav24x96, 2), (.aiff16, 4), (.aiff24Mono, 1),
    ])
    let mixedFormats = random.chance(0.03)
    let art = random.chance(0.35) ? Int.random(in: 0..<3, using: &random) : nil
    let withTrackTotal = random.chance(0.75)
    let discNumberOnSingle = random.chance(0.2)
    let untagged = random.chance(0.01)
    let vorbis = VorbisStyle(
        lowercaseKeys: random.chance(0.1), combinedTrackNumber: random.chance(0.3),
        paddingBytes: random.pick([0, 1024, 4096]))
    let id3Padding = random.pick([0, 256, 2048])
    let preferUTF16 = random.chance(0.2)
    let genreAsReference = random.chance(0.15)
    let mp3Version = random.pick(weighted: [(ID3Version.v22, 10), (.v23, 50), (.v24, 40)])
    let aiffVersion: ID3Version = random.chance(0.5) ? .v23 : .v24
    let wavLayout = random.pick(weighted: [
        ((true, false), 50), ((true, true), 35), ((false, true), 15),
    ])
    let genreAsIndex = random.chance(0.15)

    var files: [PlannedFile] = []
    for disc in 1...discs {
        for track in 1...tracksPerDisc {
            guard files.count < limit else { return files }
            let seed = mixedFormats ? random.pick(SeedKind.allCases) : albumSeed
            let title = trackTitle(&random)
            let tags = FixtureTags(
                title: title,
                artist: artist ?? random.pick(trackArtists),
                album: album,
                albumArtist: artist == nil
                    ? "Various Artists" : (random.chance(0.6) ? artist : nil),
                genre: genre, date: date, trackNumber: track,
                trackTotal: withTrackTotal ? tracksPerDisc : nil,
                discNumber: discs > 1 || discNumberOnSingle ? disc : nil,
                discTotal: discs > 1 || discNumberOnSingle ? discs : nil,
                compilation: artist == nil,
                comment: random.chance(0.1) ? random.pick(comments) : nil)
            let layout: TagLayout =
                switch seed.container {
                case .flac: .vorbis(vorbis)
                case .mp4: .mp4(genreAsIndex: genreAsIndex)
                case .mp3, .aiff:
                    .id3(
                        ID3Style(
                            version: seed.container == .mp3 ? mp3Version : aiffVersion,
                            preferUTF16: preferUTF16, genreAsReference: genreAsReference,
                            paddingBytes: id3Padding))
                case .wav:
                    .wav(
                        info: wavLayout.0,
                        id3: wavLayout.1
                            // With INFO alongside, 2.4 keeps the full date both blocks hold.
                            ? ID3Style(
                                version: wavLayout.0 ? .v24 : .v23, preferUTF16: preferUTF16,
                                genreAsReference: genreAsReference, paddingBytes: id3Padding)
                            : nil)
                }
            let number = String(format: "%02d", track)
            let name =
                (discFolders ? "Disc \(disc)/" : discs > 1 ? "\(disc)-" : "")
                + "\(number) \(fileName(title)).\(seed.fileExtension)"
            files.append(
                PlannedFile(
                    path: "\(directory)/\(name)", seed: seed, tags: untagged ? nil : tags,
                    art: untagged ? nil : art, layout: layout, malformation: nil))
        }
    }
    return files
}

/// A path component: no "/" or ":", no leading dot, and short enough in UTF-8 for the 255-byte
/// file name limit with room for a track number and extension.
private func fileName(_ name: String) -> String {
    var name = name.replacingOccurrences(of: "/", with: "-")
        .replacingOccurrences(of: ":", with: "-")
    if name.hasPrefix(".") { name = "_" + name.dropFirst() }
    while name.utf8.count > 200 { name.removeLast() }
    return name
}

private func artistName(_ random: inout SplitMix64) -> String {
    switch Int.random(in: 0..<100, using: &random) {
    case 0..<45: "\(random.pick(firstNames)) \(random.pick(lastNames))"
    case 45..<80: "The \(random.pick(adjectives)) \(random.pick(pluralNouns))"
    case 80..<95: "\(random.pick(adjectives)) \(random.pick(pluralNouns))"
    default: random.pick(nonLatinArtists)
    }
}

private func albumTitle(_ random: inout SplitMix64) -> String {
    switch Int.random(in: 0..<100, using: &random) {
    case 0..<35: "\(random.pick(nouns)) of \(random.pick(nouns))"
    case 35..<70: "\(random.pick(adjectives)) \(random.pick(nouns))"
    case 70..<95: random.pick(nouns)
    default: random.pick(unicodeTitles)
    }
}

private func trackTitle(_ random: inout SplitMix64) -> String {
    switch Int.random(in: 0..<1000, using: &random) {
    case 0..<5:
        // Longer than most tag fields and every file name.
        (0..<40).map { _ in random.pick(nouns) }.joined(separator: " ")
    case 5..<35: random.pick(unicodeTitles)
    case 35..<45: "\(random.pick(nouns)) \(random.pick(emoji))"
    case 45..<400:
        "\(random.pick(verbs)) \(random.pick(["Into", "Through", "Past", "Toward"])) \(random.pick(nouns))"
    case 400..<750: "\(random.pick(adjectives)) \(random.pick(nouns))"
    default: random.pick(nouns)
    }
}

private let firstNames = [
    "Mara", "Jonas", "Aiko", "Teodor", "Lena", "Ravi", "Odile", "Kwame", "Ingrid", "Mateo", "Yuki",
    "Saoirse", "Björn", "Zoë", "Amara", "Lucía", "Nikolai", "Hana", "Emeka", "Clémence",
]
private let lastNames = [
    "Lindqvist", "Okafor", "Tanaka", "Moreau", "Haddad", "Novak", "Castillo", "Brennan",
    "Søndergaard", "Kowalski", "Ferreira", "Nakamura", "Abernathy", "Dubois", "Iwu", "Petrov",
    "Quintero", "Halloran", "Ōtsuka", "Varga",
]
private let adjectives = [
    "Velvet", "Hollow", "Electric", "Silent", "Golden", "Paper", "Neon", "Crimson", "Wandering",
    "Lunar", "Broken", "Northern", "Quiet", "Static", "Feral", "Glass",
]
private let pluralNouns = [
    "Owls", "Harbors", "Machines", "Rivers", "Lanterns", "Satellites", "Pines", "Ghosts", "Tides",
    "Engines", "Foxes", "Cathedrals", "Mirrors", "Orchards", "Signals", "Comets",
]
private let nouns = [
    "Light", "Winter", "Salt", "Echoes", "Gravity", "Rain", "Ashes", "Summer", "Distance", "Fever",
    "Bloom", "Silence", "Thunder", "Midnight", "Honey", "Iron", "Shadows", "Harbor", "Static",
    "Daybreak", "Embers", "Satellite", "Meridian", "Undertow",
]
private let verbs = [
    "Falling", "Running", "Waiting", "Dreaming", "Burning", "Drifting", "Calling", "Breaking",
]
private let nonLatinArtists = ["坂本 美雨", "陳 綺貞", "김 윤아", "中島 みゆき", "Мумий Тролль", "Σωκράτης"]
private let unicodeTitles = [
    "Für Elise (Remastered)", "Café del Mar", "Naïve", "東京の夜", "Сердце", "Ελπίδα",
    "Ça plane pour moi", "Smörgåsbord", "Señorita", "Déjà vu", "Ñandú",
]
private let emoji = ["💃", "🌙", "🔥", "🎧"]
private let comments = [
    "Recorded live", "Remastered 2011", "Bonus track", "Vinyl rip", "Contains a hidden track",
]
