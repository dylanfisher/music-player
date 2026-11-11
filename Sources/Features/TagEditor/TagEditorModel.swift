import Foundation
import Library
import Metadata
import Settings
import TagWriter

/// A track as the editor opens it: its tags and art read from the file, not from the index, so
/// the editor starts from what's really there.
package struct EditableTrack: Equatable, Sendable {
    var path: String
    var tags: TrackTags
    /// Every picture it embeds, in its order. MP4's have no types, so its first reads as the
    /// front cover and the rest as Other.
    var pictures: [ArtPicture]
    /// Fields whose frame or item holds several values, of which the editor shows the first.
    var multiValued: Set<TagEditField>
    /// What the File tab shows; nil when not read, as in tests.
    var file: FileFacts?
    /// Why its tags can't be written, as for a DSF file, which the window shows read-only; nil
    /// when they can.
    var readOnly: String?
    /// Its play count in the index, not the file; nil when the index has no track at its path
    /// or it wasn't read.
    var playCount: Int?
    /// Its rating in the index, 0 for unrated; nil when the index has no track at its path or
    /// it wasn't read.
    var rating: Int?

    init(
        path: String, tags: TrackTags, pictures: [ArtPicture],
        multiValued: Set<TagEditField> = [], file: FileFacts? = nil, readOnly: String? = nil,
        playCount: Int? = nil, rating: Int? = nil
    ) {
        self.path = path
        self.tags = tags
        self.pictures = pictures
        self.multiValued = multiValued
        self.file = file
        self.readOnly = readOnly
        self.playCount = playCount
        self.rating = rating
    }
}

/// A file's format, size and dates, which Get Info shows and doesn't edit.
struct FileFacts: Equatable, Sendable {
    var audio: TrackAudio
    var sizeBytes: Int
    /// "ID3v2.4", "Vorbis comment" and the like.
    var tagScheme: String
    var modified: Date
    var created: Date
}

/// The tag editor's state for one track or many: each field's value where the tracks agree or
/// "mixed" where they don't, what the user typed, the Extras tab's keys, and the art. Typed text
/// stays as typed until `edit()` checks it.
public struct TagEditorModel: Equatable, Sendable {
    public enum Art: Equatable, Sendable {
        case unchanged
        /// Replace Artwork…: the front cover, the files' other pictures kept.
        case replaced(Data, mimeType: String)
        case removed
        /// The Artwork tab's list, edited: every picture each file is to hold.
        case pictures([ArtPicture])
    }

    private(set) var tracks: [EditableTrack]
    /// What the user typed, by field, including fields typed back to their old value.
    private(set) var typed: [TagEditField: String] = [:]
    public private(set) var art = Art.unchanged
    /// What the user typed in Extras, by key, uppercased as the reader gives them, including
    /// keys added and values typed back to what they were.
    private(set) var typedExtras: [String: String] = [:]
    /// Keys the user deleted in Extras that some track holds.
    private(set) var deletedExtras: Set<String> = []
    /// What the user typed as the play count, which isn't a tag (ADR 0162).
    private(set) var typedPlayCount: String?

    init(tracks: [EditableTrack]) {
        precondition(!tracks.isEmpty, "the editor opens on at least one track")
        self.tracks = tracks
    }

    /// The same files as read again after a write: what the user typed, in Extras too, and the
    /// art they chose stay, and every other field shows what the files hold now.
    mutating func reread(_ tracks: [EditableTrack]) {
        precondition(
            tracks.map(\.path) == self.tracks.map(\.path), "a reread holds the same files")
        self.tracks = tracks
    }

    /// The tracks Save writes: those whose tags can be written. The fields show every track's
    /// values, but an edit is checked against and written to only these.
    var writable: [EditableTrack] { tracks.filter { $0.readOnly == nil } }

    /// Whether any track can be saved, which turns the fields, the art buttons and Save on.
    var canSave: Bool { !writable.isEmpty }

    /// The tracks a play count typed goes to: those the index has a track for, read-only files
    /// included, since it's stored in the index, not the file.
    var countedPaths: [String] { tracks.filter { $0.playCount != nil }.map(\.path) }

    /// The tracks a click on the stars rates: those the index has a track for.
    var ratedPaths: [String] { tracks.filter { $0.rating != nil }.map(\.path) }

    /// The rating every rated track has, 0 for unrated or with none rated; nil when they
    /// differ.
    var shownRating: Int? {
        let ratings = Set(tracks.compactMap(\.rating))
        return ratings.count > 1 ? nil : ratings.first ?? 0
    }

    /// Gives every rated track `stars`, as a click on the stars sets it in the index. It isn't
    /// an edit: Save has nothing more to store.
    mutating func setRating(_ stars: Int) {
        for index in tracks.indices where tracks[index].rating != nil {
            tracks[index].rating = stars
        }
    }

    /// The ratings the index has now, one per track, as `setRating` would leave them.
    mutating func showRatings(_ ratings: [Int?]) {
        precondition(ratings.count == tracks.count, "a rating for each track")
        for (index, rating) in ratings.enumerated() { tracks[index].rating = rating }
    }

    /// Whether Save can store anything: tags, or a play count.
    var canSaveAnything: Bool { canSave || !countedPaths.isEmpty }

    /// The play count every counted track has, or nil when they differ; empty with none.
    private var sharedPlayCount: String? {
        let counts = Set(tracks.compactMap(\.playCount))
        return counts.count > 1 ? nil : counts.first.map(String.init) ?? ""
    }

    /// What the Plays field shows: the count typed, else the one the tracks share.
    var playCountText: String { typedPlayCount ?? sharedPlayCount ?? "" }

    var isPlayCountMixed: Bool { typedPlayCount == nil && sharedPlayCount == nil }

    /// Whether saving would change the play count: it was typed differently from what it showed.
    var isPlayCountEdited: Bool { typedPlayCount.map { $0 != sharedPlayCount } ?? false }

    mutating func setPlayCount(_ text: String) { typedPlayCount = text }

    /// The play count Save stores for `countedPaths`; nil when it isn't edited. Call after
    /// `checkPlayCount`.
    var playCountChange: Int? {
        guard isPlayCountEdited, let typed = typedPlayCount else { return nil }
        return Int(typed)
    }

    /// Throws unless the play count typed, if edited, is a whole number from 0 to the most a
    /// sync log takes. Empty isn't a count.
    func checkPlayCount() throws(PlayCountError) {
        guard isPlayCountEdited, let typed = typedPlayCount else { return }
        guard typed.allSatisfy({ $0.isASCII && $0.isNumber }), let count = Int(typed),
            count <= maximumPlayCount
        else { throw PlayCountError(text: typed) }
    }

    /// Why some tracks can't be saved, and, when others can, how many Save writes; nil when
    /// every track can.
    var readOnlyNote: String? {
        var reasons: [String] = []
        for track in tracks {
            if let reason = track.readOnly, !reasons.contains(reason) { reasons.append(reason) }
        }
        guard !reasons.isEmpty else { return nil }
        let why = reasons.joined(separator: ". ") + "."
        let count = writable.count
        guard count > 0 else { return why }
        return why + " Save writes only the other \(count) file\(count == 1 ? "" : "s")."
    }

    func isTyped(_ field: TagEditField) -> Bool { typed[field] != nil }

    /// Whether saving would change the field: it was typed differently from what it showed.
    func isEdited(_ field: TagEditField) -> Bool {
        typed[field].map { $0 != shared(field) } ?? false
    }

    /// The field's text in every track, or nil when they differ. Empty when none has it.
    public func shared(_ field: TagEditField) -> String? {
        let first = text(field, in: tracks[0].tags)
        return tracks.dropFirst().allSatisfy { text(field, in: $0.tags) == first } ? first : nil
    }

    func isMixed(_ field: TagEditField) -> Bool {
        typed[field] == nil && shared(field) == nil
    }

    /// What the field shows: the typed text, else the shared value; empty when mixed.
    public func text(_ field: TagEditField) -> String { typed[field] ?? shared(field) ?? "" }

    public mutating func set(_ field: TagEditField, _ text: String) { typed[field] = text }

    /// Fields the edit changes that hold several values in some track, which saving collapses
    /// to the one shown.
    var collapsedFields: [TagEditField] {
        let typedChanges = Set(typed.filter { shared($0.key) != $0.value }.keys)
        return TagEditField.allCases.filter { field in
            typedChanges.contains(field) && writable.contains { $0.multiValued.contains(field) }
        }
    }

    /// What the sheet says about `collapsedFields` before the user saves; nil when none.
    var collapseNote: String? {
        let fields = collapsedFields
        guard !fields.isEmpty else { return nil }
        let files = writable.filter { !$0.multiValued.isDisjoint(with: fields) }.count
        let names = fields.map(\.title).joined(separator: ", ")
        return "\(names) \(fields.count == 1 ? "holds" : "hold") several values in \(files)"
            + " file\(files == 1 ? "" : "s"). Saving keeps only the value shown."
    }

    /// The pictures every track holds, or nil when they differ.
    private var sharedPictures: [ArtPicture]? {
        let first = tracks[0].pictures
        return tracks.dropFirst().allSatisfy { $0.pictures == first } ? first : nil
    }

    /// The pictures the Artwork tab lists: the tracks' when they share them, none when mixed,
    /// and as edited once they are. A replaced front cover takes the place of the picture
    /// shown, as the writer puts it.
    var shownPictures: [ArtPicture] {
        switch art {
        case .unchanged: return sharedPictures ?? []
        case .removed: return []
        case .pictures(let pictures): return pictures
        case .replaced(let image, let mimeType):
            let front = ArtPicture(image: image, mimeType: mimeType, type: .frontCover)
            var pictures = sharedPictures ?? []
            guard let index = shownIndex(pictures) else { return [front] }
            pictures[index] = front
            return pictures
        }
    }

    /// The art to show: the front cover, else the first picture; nil for none or mixed.
    var shownArt: Data? { shownIndex(shownPictures).map { shownPictures[$0].image } }

    /// Where the picture players show is in `pictures`: the front cover, else the first.
    private func shownIndex(_ pictures: [ArtPicture]) -> Int? {
        pictures.firstIndex { $0.type == .frontCover } ?? (pictures.isEmpty ? nil : 0)
    }

    var isArtMixed: Bool { art == .unchanged && sharedPictures == nil }

    /// Whether Remove Artwork would change anything.
    public var canRemoveArt: Bool {
        switch art {
        case .replaced: true
        case .removed: false
        case .pictures(let pictures): !pictures.isEmpty
        case .unchanged: writable.contains { !$0.pictures.isEmpty }
        }
    }

    mutating func replaceArt(_ image: Data, mimeType: String) {
        art = .replaced(image, mimeType: mimeType)
    }

    public mutating func removeArt() { art = .removed }

    /// Adds images after the pictures listed, the first a front cover when none is listed,
    /// the rest Other until a type is chosen. Added to mixed art, they become every file's
    /// only pictures.
    mutating func addPictures(_ images: [(data: Data, mimeType: String)]) {
        var pictures = shownPictures
        for image in images {
            let type: PictureType =
                pictures.contains { $0.type == .frontCover } ? .other : .frontCover
            pictures.append(ArtPicture(image: image.data, mimeType: image.mimeType, type: type))
        }
        setPictures(pictures)
    }

    mutating func removePictures(at indices: IndexSet) {
        let pictures = shownPictures.enumerated().filter { !indices.contains($0.offset) }
        setPictures(pictures.map(\.element))
    }

    mutating func setPictureType(_ type: PictureType, at index: Int) {
        var pictures = shownPictures
        guard pictures.indices.contains(index), pictures[index].type != type else { return }
        pictures[index].type = type
        setPictures(pictures)
    }

    /// The list edited to `pictures`: no edit when the tracks hold just those already.
    private mutating func setPictures(_ pictures: [ArtPicture]) {
        art =
            pictures == sharedPictures
            ? .unchanged : pictures.isEmpty ? .removed : .pictures(pictures)
    }

    /// The edit to write: every field and Extras key typed differently from what it showed, the
    /// Extras keys deleted, and the art. Throws for a value some writable track can't take,
    /// before anything is written.
    func edit() throws(TagValueError) -> TagEdit {
        var values: [TagEditField: String] = [:]
        for (field, text) in typed where shared(field) != text { values[field] = text }
        var custom: [String: String] = [:]
        for (key, text) in typedExtras where sharedExtra(key) != text { custom[key] = text }
        for key in deletedExtras where writable.contains(where: { $0.tags.custom[key] != nil }) {
            custom[key] = ""
        }
        if let typed = custom[DiscogsKey.releaseID], !typed.isEmpty, !isReleaseID(typed) {
            throw TagValueError(
                customKey: DiscogsKey.releaseID, text: typed,
                detail: "isn't a Discogs release id, a whole number above 0")
        }
        // The writer refuses a whole file for such a key, even one it would only remove.
        for (key, text) in custom.sorted(by: { $0.key < $1.key }) {
            if let problem = id3OnlyProblem(key) {
                throw TagValueError(customKey: key, text: text, detail: problem)
            }
        }
        let artChange: ArtChange? =
            switch art {
            case .unchanged: nil
            case .replaced(let image, let mimeType): .replace(image, mimeType: mimeType)
            case .removed: .remove
            case .pictures(let pictures): .pictures(pictures)
            }
        let edit = TagEdit(values: values, custom: custom, art: artChange)
        for track in writable { _ = try edit.applied(to: track.tags) }
        return edit
    }

    /// What the Extras tab lists: every key the reader found that no field maps (ADR 0129), by
    /// key, with the keys added and less those deleted. A key's value is what was typed, else
    /// it shows when every track has it and they agree; otherwise it's mixed, a key some tracks
    /// lack included. Keys another tab shows, as the Discogs ones, are listed too: this is what
    /// the files hold, not what's left unshown.
    var extras: [ExtraRow] {
        let keys = Set(tracks.flatMap(\.tags.custom.keys)).union(typedExtras.keys)
            .subtracting(deletedExtras).sorted()
        return keys.map { key in
            ExtraRow(
                key: key, value: typedExtras[key] ?? sharedExtra(key),
                isEdited: typedExtras[key].map { $0 != sharedExtra(key) } ?? false)
        }
    }

    /// Key `key`'s value in every track, or nil when they differ or some lack it. Empty when
    /// none has it.
    private func sharedExtra(_ key: String) -> String? {
        let first = tracks[0].tags.custom[key]
        return tracks.dropFirst().allSatisfy { $0.tags.custom[key] == first } ? first ?? "" : nil
    }

    /// Sets `key`, a key `extras` lists, to `text` in every track. Empty text removes the key
    /// when saved.
    mutating func setExtra(_ key: String, _ text: String) {
        typedExtras[key] = text
        deletedExtras.remove(key)
    }

    /// Takes `key` out of every track when saved, or drops it if it was only added.
    mutating func deleteExtra(_ key: String) {
        typedExtras[key] = nil
        if tracks.contains(where: { $0.tags.custom[key] != nil }) { deletedExtras.insert(key) }
    }

    /// Adds key `name` to Extras, uppercased as the reader gives every key, with no value until
    /// one is typed; a key deleted comes back with the value it showed. Returns why it can't be
    /// added, adding nothing: a name no format can hold or a field's (it would read back as
    /// that field), an ID3 frame for a file of another format, or a key already listed.
    mutating func addExtra(_ name: String) -> String? {
        if let problem = customKeyProblem(name) { return "\"\(name)\" \(problem)" }
        let key = name.uppercased()
        if let problem = id3OnlyProblem(key) { return "\"\(key)\" \(problem)" }
        guard !extras.contains(where: { $0.key == key }) else {
            return "\"\(key)\" is already in Extras"
        }
        if deletedExtras.remove(key) == nil { typedExtras[key] = "" }
        return nil
    }

    /// Why `key` can't be written to every writable track: it's a frame only ID3 holds, and
    /// some track is another format. Nil when it can, or when no track's format is known.
    private func id3OnlyProblem(_ key: String) -> String? {
        guard ID3CustomKey.isID3Only(key),
            let other = writable.lazy.compactMap({ $0.file.flatMap { TagFormat($0.audio.codec) } })
                .first(where: { $0 != .id3 })
        else { return nil }
        return "is an ID3 frame, which \(other.rawValue) doesn't hold"
    }

    /// The release id the user gave: the one typed, empty once deleted in Extras, nil for
    /// neither.
    private var editedReleaseID: String? {
        typedExtras[DiscogsKey.releaseID]
            ?? (deletedExtras.contains(DiscogsKey.releaseID) ? "" : nil)
    }

    /// What the Discogs tab's Release ID field shows: the id typed, else the one every track
    /// holds; empty when deleted, mixed or none has one.
    var releaseIDText: String {
        editedReleaseID ?? sharedExtra(DiscogsKey.releaseID) ?? ""
    }

    /// Whether the tracks hold different release ids, or some none, and none was typed.
    var isReleaseIDMixed: Bool {
        editedReleaseID == nil && sharedExtra(DiscogsKey.releaseID) == nil
    }

    /// The release the Discogs tab shows: the id typed, while it's one, else the first the
    /// tracks hold, each once.
    var shownReleaseIDs: [Int] {
        guard let edited = editedReleaseID else { return discogsReleaseIDs }
        return isReleaseID(edited) ? [Int(edited)!] : []
    }

    /// The Discogs release ids the tracks carry, each once, in the tracks' order; a value that
    /// isn't a number is left out.
    var discogsReleaseIDs: [Int] {
        var seen = Set<Int>()
        return tracks.compactMap { $0.tags.custom[DiscogsKey.releaseID].flatMap { Int($0) } }
            .filter { seen.insert($0).inserted }
    }

    private func text(_ field: TagEditField, in tags: TrackTags) -> String {
        if let property = field.textField?.textProperty { return tags[keyPath: property] ?? "" }
        if let property = field.numberProperty {
            return tags[keyPath: property].map(String.init) ?? ""
        }
        return tags.compilation ? "1" : ""
    }
}

/// Whether `text` is a Discogs release id: a whole number above 0, in ASCII digits.
private func isReleaseID(_ text: String) -> Bool {
    text.allSatisfy { $0.isASCII && $0.isNumber } && (Int(text) ?? 0) > 0
}

/// A play count typed that isn't one, worded as `TagValueError` words a field's: its name,
/// the text and why.
struct PlayCountError: Error, Equatable, CustomStringConvertible {
    var text: String

    var description: String {
        "\(TrackColumn.playCount.rawValue) \"\(text)\" isn't a whole number from 0 to"
            + " \(maximumPlayCount)"
    }
}

/// A row of the Extras tab: a key and its value, nil where the tracks differ.
struct ExtraRow: Equatable {
    var key: String
    var value: String?
    /// Whether saving would change it: it was typed differently from what it showed.
    var isEdited = false
}

/// Reads each file's tags and art for the editor, through `read`, `filesReadAtOnce` at a time,
/// since on a NAS each file waits on a few round trips. A file that can't be read is reported
/// and left out, so the rest can still be edited. Both lists keep the order of `paths`. Once
/// `isStopped` says so, as when the info window closes, no further file is started, and what
/// was read comes back.
package func readEditableTracks(
    _ paths: [String], isStopped: @Sendable () -> Bool = { false },
    read: @Sendable (String) throws -> EditableTrack = readEditableTrack
) -> (tracks: [EditableTrack], problems: [String]) {
    let results = ReadResults(count: paths.count)
    DispatchQueue.concurrentPerform(iterations: min(filesReadAtOnce, paths.count)) { _ in
        while !isStopped(), let index = results.claim() {
            results.store(Result { try read(paths[index]) }, at: index)
        }
    }
    var tracks: [EditableTrack] = []
    var problems: [String] = []
    for result in results.all {
        switch result {
        case .success(let track): tracks.append(track)
        case .failure(let error): problems.append("\(error)")
        case nil: break
        }
    }
    return (tracks, problems)
}

/// The files `readEditableTracks` has handed out, and what each read returned.
private final class ReadResults: @unchecked Sendable {
    // Every field is guarded by `lock`.
    private let lock = NSLock()
    private var claimed = 0
    private var results: [Result<EditableTrack, any Error>?]

    init(count: Int) { results = Array(repeating: nil, count: count) }

    /// The next file to read, or nil when every one is taken.
    func claim() -> Int? {
        lock.withLock {
            guard claimed < results.count else { return nil }
            claimed += 1
            return claimed - 1
        }
    }

    func store(_ result: Result<EditableTrack, any Error>, at index: Int) {
        lock.withLock { results[index] = result }
    }

    /// Every file's result, nil for one a stop left unread.
    var all: [Result<EditableTrack, any Error>?] { lock.withLock { results } }
}

/// The tags, art and fields holding several values of the file at `path`, through one open,
/// since on a NAS each open is a few round trips. The tags and the fields holding several
/// values come from the same first read.
package func readEditableTrack(_ path: String) throws -> EditableTrack {
    do throws(ParseFailure) {
        let source = try FileSource(path: path)
        let reader = ByteReader(source, keepsPictures: true)
        let parsed = try parse(reader)
        var pictures: [ArtPicture] = []
        for picture in parsed.metadata.pictures {
            let type = picture.type ?? (pictures.isEmpty ? .frontCover : .other)
            pictures.append(
                ArtPicture(
                    image: try readArt(picture.art, from: source),
                    mimeType: picture.art.mimeType, type: type))
        }
        let facts = try editorTagFacts(
            in: reader, hasTags: !parsed.metadata.tags.isEmpty || parsed.metadata.art != nil)
        // The dates come from the open descriptor's stat, so they cost no extra round trip.
        let file = FileFacts(
            audio: parsed.metadata.audio, sizeBytes: reader.size, tagScheme: facts.tagScheme,
            modified: source.modified, created: source.created)
        return EditableTrack(
            path: path, tags: parsed.metadata.tags, pictures: pictures,
            multiValued: facts.multiValued,
            file: file, readOnly: facts.readOnly)
    } catch {
        throw error.error(path: path)
    }
}
