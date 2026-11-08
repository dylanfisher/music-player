import Foundation
import Metadata
import TagWriter

/// A track as the editor opens it: its tags and art read from the file, not from the index, so
/// the editor starts from what's really there.
package struct EditableTrack: Equatable, Sendable {
    var path: String
    var tags: TrackTags
    var art: Data?
    /// Fields whose frame or item holds several values, of which the editor shows the first.
    var multiValued: Set<TagEditField>
    /// What the File tab shows; nil when not read, as in tests.
    var file: FileFacts?
    /// Why its tags can't be written, as for a DSF file, which the window shows read-only; nil
    /// when they can.
    var readOnly: String?

    init(
        path: String, tags: TrackTags, art: Data?, multiValued: Set<TagEditField> = [],
        file: FileFacts? = nil, readOnly: String? = nil
    ) {
        self.path = path
        self.tags = tags
        self.art = art
        self.multiValued = multiValued
        self.file = file
        self.readOnly = readOnly
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
/// "mixed" where they don't, what the user typed, and the art. Typed text stays as typed until
/// `edit()` checks it.
public struct TagEditorModel: Equatable, Sendable {
    public enum Art: Equatable, Sendable {
        case unchanged
        case replaced(Data, mimeType: String)
        case removed
    }

    private(set) var tracks: [EditableTrack]
    /// What the user typed, by field, including fields typed back to their old value.
    private(set) var typed: [TagEditField: String] = [:]
    public private(set) var art = Art.unchanged

    init(tracks: [EditableTrack]) {
        precondition(!tracks.isEmpty, "the editor opens on at least one track")
        self.tracks = tracks
    }

    /// The same files as read again after a write: what the user typed and the art they chose
    /// stay, and every other field shows what the files hold now.
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

    /// The art to show: the new art, none once removed, or the tracks' art when they share it.
    var shownArt: Data? {
        switch art {
        case .replaced(let image, _): image
        case .removed: nil
        case .unchanged: isArtMixed ? nil : tracks[0].art
        }
    }

    var isArtMixed: Bool {
        art == .unchanged && tracks.dropFirst().contains { $0.art != tracks[0].art }
    }

    /// Whether Remove Artwork would change anything.
    public var canRemoveArt: Bool {
        switch art {
        case .replaced: true
        case .removed: false
        case .unchanged: writable.contains { $0.art != nil }
        }
    }

    mutating func replaceArt(_ image: Data, mimeType: String) {
        art = .replaced(image, mimeType: mimeType)
    }

    public mutating func removeArt() { art = .removed }

    /// The edit to write: every field typed differently from what it showed, and the art. Throws
    /// for a value some writable track can't take, before anything is written.
    func edit() throws(TagValueError) -> TagEdit {
        var values: [TagEditField: String] = [:]
        for (field, text) in typed where shared(field) != text { values[field] = text }
        let artChange: ArtChange? =
            switch art {
            case .unchanged: nil
            case .replaced(let image, let mimeType): .replace(image, mimeType: mimeType)
            case .removed: .remove
            }
        let edit = TagEdit(values: values, art: artChange)
        for track in writable { _ = try edit.applied(to: track.tags) }
        return edit
    }

    /// What the Extras tab lists: every key the reader found that no field maps (ADR 0129), by
    /// key. A key's value shows when every track has it and they agree; otherwise it's mixed,
    /// a key some tracks lack included. Keys another tab shows, as the Discogs ones, are listed
    /// too: this is what the files hold, not what's left unshown.
    var extras: [ExtraRow] {
        let keys = Set(tracks.flatMap(\.tags.custom.keys)).sorted()
        return keys.map { key in
            let values = tracks.map { $0.tags.custom[key] }
            let first = values[0]
            return ExtraRow(
                key: key, value: values.allSatisfy { $0 == first } ? first : nil)
        }
    }

    /// The Discogs release ids the tracks carry, each once, in the tracks' order; a value that
    /// isn't a number is left out. The Discogs tab shows the first.
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

/// A row of the Extras tab: a key and its value, nil where the tracks differ.
struct ExtraRow: Equatable {
    var key: String
    var value: String?
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
        let reader = ByteReader(source)
        let parsed = try parse(reader)
        let art = try parsed.metadata.art.map { art throws(ParseFailure) in
            try readArt(art, from: source)
        }
        let facts = try editorTagFacts(
            in: reader, hasTags: !parsed.metadata.tags.isEmpty || parsed.metadata.art != nil)
        // The dates come from the open descriptor's stat, so they cost no extra round trip.
        let file = FileFacts(
            audio: parsed.metadata.audio, sizeBytes: reader.size, tagScheme: facts.tagScheme,
            modified: source.modified, created: source.created)
        return EditableTrack(
            path: path, tags: parsed.metadata.tags, art: art, multiValued: facts.multiValued,
            file: file, readOnly: facts.readOnly)
    } catch {
        throw error.error(path: path)
    }
}
