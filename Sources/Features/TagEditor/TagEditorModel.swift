import Foundation
import Metadata
import TagWriter

/// A track as the editor opens it: its tags and art read from the file, not from the index, so
/// the editor starts from what's really there.
struct EditableTrack: Equatable, Sendable {
    var path: String
    var tags: TrackTags
    var art: Data?
    /// Fields whose frame or item holds several values, of which the editor shows the first.
    var multiValued: Set<TagEditField>

    init(path: String, tags: TrackTags, art: Data?, multiValued: Set<TagEditField> = []) {
        self.path = path
        self.tags = tags
        self.art = art
        self.multiValued = multiValued
    }
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

    let tracks: [EditableTrack]
    /// What the user typed, by field, including fields typed back to their old value.
    private(set) var typed: [TagEditField: String] = [:]
    public private(set) var art = Art.unchanged

    init(tracks: [EditableTrack]) {
        precondition(!tracks.isEmpty, "the editor opens on at least one track")
        self.tracks = tracks
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
            typedChanges.contains(field) && tracks.contains { $0.multiValued.contains(field) }
        }
    }

    /// What the sheet says about `collapsedFields` before the user saves; nil when none.
    var collapseNote: String? {
        let fields = collapsedFields
        guard !fields.isEmpty else { return nil }
        let files = tracks.filter { !$0.multiValued.isDisjoint(with: fields) }.count
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
        case .unchanged: tracks.contains { $0.art != nil }
        }
    }

    mutating func replaceArt(_ image: Data, mimeType: String) {
        art = .replaced(image, mimeType: mimeType)
    }

    public mutating func removeArt() { art = .removed }

    /// The edit to write: every field typed differently from what it showed, and the art. Throws
    /// for a value some track can't take, before anything is written.
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
        for track in tracks { _ = try edit.applied(to: track.tags) }
        return edit
    }

    private func text(_ field: TagEditField, in tags: TrackTags) -> String {
        let value: String? =
            switch field {
            case .title: tags.title
            case .artist: tags.artist
            case .album: tags.album
            case .albumArtist: tags.albumArtist
            case .genre: tags.genre
            case .date: tags.date
            case .composer: tags.composer
            case .comment: tags.comment
            case .trackNumber: tags.trackNumber.map(String.init)
            case .trackTotal: tags.trackTotal.map(String.init)
            case .discNumber: tags.discNumber.map(String.init)
            case .discTotal: tags.discTotal.map(String.init)
            case .compilation: tags.compilation ? "1" : ""
            }
        return value ?? ""
    }
}

/// Reads each file's tags and art for the editor. A file that can't be read is reported and
/// left out, so the rest can still be edited.
func readEditableTracks(_ paths: [String]) -> (tracks: [EditableTrack], problems: [String]) {
    var tracks: [EditableTrack] = []
    var problems: [String] = []
    for path in paths {
        let url = URL(fileURLWithPath: path)
        do {
            let parsed = try readMetadata(at: url)
            let art = try parsed.metadata.art.map { try readArt($0, at: url) }
            tracks.append(
                EditableTrack(
                    path: path, tags: parsed.metadata.tags, art: art,
                    multiValued: try multiValuedFields(at: url)))
        } catch {
            problems.append("\(error)")
        }
    }
    return (tracks, problems)
}
