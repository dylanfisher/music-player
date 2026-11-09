import Foundation
import Metadata
import Settings
import TagWriter

/// One file of an album as the tagger compares it: its id in the index, where it is, and the
/// tags read from it now.
public struct AlbumFile: Sendable {
    public var id: Int64
    public var path: String
    public var metadata: TrackMetadata
}

/// A tag the mapping would change in one file: what it holds now and what it would hold
/// (ADR 0132), a row of the View Changes sheet.
public struct TagChange: Equatable, Sendable, Identifiable {
    public struct ID: Hashable, Sendable {
        public var fileID: Int64
        public var tag: MappedTag
    }

    public var id: ID
    /// The Discogs field the value comes from.
    public var field: DiscogsField
    /// Nil for a tag the file doesn't have.
    public var current: String?
    /// Nil to remove the tag: a numbered key past the release's values, a tag of a field
    /// Discogs has no value for, or another spelling of the field's key (ADR 0152).
    public var new: String?

    public var tag: MappedTag { id.tag }
}

/// What the mapping would change in one file.
public struct FileChanges: Equatable, Sendable {
    public var fileID: Int64
    public var path: String
    /// In the order of the mapping's fields, then of their targets.
    public var changes: [TagChange]
    /// Why nothing can be written to the file, as for a DSD file; nil when it can be.
    public var unwritable: String?
    /// The tags the changes were worked out from.
    var tags: TrackTags
    /// Whether the file has a cover now.
    var hasCover = false
    /// What the album's cover does to this file.
    public internal(set) var cover = CoverState.none
}

/// What an album's cover does to one file (ADR 0140).
public enum CoverState: Equatable, Sendable {
    /// Nothing: no cover, the mode is off, or it fills only empty ones and the file has one.
    case none
    case adds
    case replaces
}

/// Every change the mapping would make to an album's files for its match: the model of the
/// View Changes sheet and of Apply (ADR 0132). Nothing here reads or writes a file.
public struct AlbumChangeSet: Equatable, Sendable {
    public var files: [FileChanges]
    /// The release's cover, which each file's `cover` says what it does to.
    public private(set) var cover: Cover?

    /// The set with `cover` going to each file that `mode` gives it: every writable one for
    /// replace, those with no cover for fill empty, none for off.
    public func covering(_ cover: Cover, mode: DiscogsArtworkMode) -> AlbumChangeSet {
        var set = self
        set.cover = mode == .off ? nil : cover
        for index in set.files.indices {
            let file = set.files[index]
            set.files[index].cover =
                switch mode {
                case _ where file.unwritable != nil: .none
                case .off: .none
                case .fillEmpty: file.hasCover ? .none : .adds
                case .replace: file.hasCover ? .replaces : .adds
                }
        }
        return set
    }

    /// The files the cover goes to.
    public var coveredFiles: Int { cover == nil ? 0 : files.count { $0.cover != .none } }

    /// Each file's edit with the changes `isIncluded` keeps, and the cover unless
    /// `includingCover` is off, as `TagWriter` writes it, in the same batch; a file left with
    /// no change has no edit. Throws for a value no format can hold, naming it, so the sheet
    /// can show it before anything is written.
    public func edits(
        including isIncluded: (TagChange.ID) -> Bool = { _ in true }, includingCover: Bool = true
    ) throws(TagValueError) -> [(path: String, edit: TagEdit)] {
        var edits: [(path: String, edit: TagEdit)] = []
        for file in files where file.unwritable == nil {
            var edit = TagEdit()
            for change in file.changes where isIncluded(change.id) {
                switch change.tag {
                case .field(let field): edit.values[field] = change.new ?? ""
                case .custom(let name): edit.custom[name] = change.new ?? ""
                }
            }
            if includingCover, let cover, file.cover != .none {
                edit.art = .replace(cover.bytes, mimeType: cover.mimeType)
            }
            guard !edit.isEmpty else { continue }
            _ = try edit.applied(to: file.tags)
            edits.append((file.path, edit))
        }
        return edits
    }
}

/// What the mapping would write to `files` for `match` (ADR 0132). A file the match maps to a
/// track gets every field; one it maps to none, such as a bonus track the release lacks, gets
/// the release's fields only. A field set to fill empty tags leaves a tag that has a value. One
/// that replaces them clears its tags when Discogs has no value for it, and removes the other
/// spellings of its key a file holds (ADR 0152). `fillingSortArtist` gives a
/// file with no sort artist the album artist the changes write, else its own (ADR 0132).
public func changeSet(
    for files: [AlbumFile], match: AlbumMatch, mapping: DiscogsMapping,
    fillingSortArtist: Bool = false
) -> AlbumChangeSet {
    guard let release = match.release else {
        return AlbumChangeSet(
            files: files.map {
                FileChanges(
                    fileID: $0.id, path: $0.path, changes: [], unwritable: nil,
                    tags: $0.metadata.tags)
            })
    }
    let fields = ReleaseFields(release, tracks: match.tracks)
    return AlbumChangeSet(
        files: files.map { file in
            guard let format = TagFormat(file.metadata.audio.codec) else {
                return FileChanges(
                    fileID: file.id, path: file.path, changes: [],
                    unwritable: "Tags in DSD files can't be written yet",
                    tags: file.metadata.tags)
            }
            let place = match.mapping[file.id].map { fields.places[$0] }
            var changes = changes(
                file, format: format, place: place, fields: fields, mapping: mapping)
            if fillingSortArtist, let sorted = sortArtist(file, changes) {
                changes.append(sorted)
            }
            return FileChanges(
                fileID: file.id, path: file.path, changes: changes, unwritable: nil,
                tags: file.metadata.tags, hasCover: file.metadata.art != nil)
        })
}

private func changes(
    _ file: AlbumFile, format: TagFormat, place: ReleaseFields.Place?, fields: ReleaseFields,
    mapping: DiscogsMapping
) -> [TagChange] {
    let tags = file.metadata.tags
    let mappingKeys = DiscogsField.allCases.flatMap { field in
        mapping[field].mode == .off ? [] : mapping[field].targets.filter(\.isKey)
    }
    var result: [TagChange] = []
    for field in DiscogsField.allCases {
        let rule = mapping[field]
        // A track's field for a file the match maps to no track is left as it is.
        guard rule.mode != .off, field.level == .release || place != nil else { continue }
        let value = fields.value(field, at: place)
        guard value != nil || rule.mode == .replace else { continue }
        var pairs: [(MappedTag, String?)] = []
        for target in rule.targets {
            if let value {
                pairs += written(
                    field, value, rule.format, target, format: format, fields: fields,
                    place: place, tags: tags)
            } else {
                pairs += held(target, format, in: tags).map { ($0, nil) }
            }
        }
        if rule.mode == .replace, rule.targets.contains(where: \.isKey) {
            pairs += otherSpellings(of: field, in: tags, keeping: mappingKeys, format).map {
                ($0, nil)
            }
        }
        for (tag, new) in pairs {
            let current = text(tag, in: tags)
            if rule.mode == .fillEmpty, current != nil { continue }
            guard new != current else { continue }
            result.append(
                TagChange(
                    id: TagChange.ID(fileID: file.id, tag: tag), field: field,
                    current: current, new: new))
        }
    }
    return result
}

/// The tags of `target` in `format` that `tags` holds: its field or key, and its numbered keys.
private func held(_ target: DiscogsTarget, _ format: TagFormat, in tags: TrackTags)
    -> [MappedTag]
{
    guard target.isKey else {
        let tag = target.tag(in: format)
        return text(tag, in: tags) == nil ? [] : [tag]
    }
    return tags.custom.keys.sorted().filter { spells($0, target, format) }.map(MappedTag.custom)
}

/// The keys `tags` holds that another preset, or an early build, spells `field`'s tags with,
/// in any format, and that none of `mappingKeys` in `format` spells (ADR 0152).
private func otherSpellings(
    of field: DiscogsField, in tags: TrackTags, keeping mappingKeys: [DiscogsTarget],
    _ format: TagFormat
) -> [MappedTag] {
    let spellings = DiscogsPreset.spellings[field] ?? []
    return tags.custom.keys.sorted().filter { key in
        spellings.contains { target in TagFormat.allCases.contains { spells(key, target, $0) } }
            && !mappingKeys.contains { spells(key, $0, format) }
    }.map(MappedTag.custom)
}

/// Whether `key`, uppercased, is `target`'s key in `format` or one of its numbered keys.
private func spells(_ key: String, _ target: DiscogsTarget, _ format: TagFormat) -> Bool {
    guard case .custom(let name) = target.tag(in: format) else { return false }
    if key == name.uppercased() { return true }
    guard case .custom(let second)? = target.tag(in: format, value: 1) else { return false }
    let prefix = second.uppercased().dropLast()
    guard key.hasPrefix(prefix), let number = Int(key.dropFirst(prefix.count)) else {
        return false
    }
    return number > 1
}

/// `ARTISTSORT` as the owner's YATE fills it after an import: the album artist the changes
/// write, else the file's, where the file has no sort artist and the mapping writes none.
private func sortArtist(_ file: AlbumFile, _ changes: [TagChange]) -> TagChange? {
    let tag = MappedTag.field(.artistSort)
    guard text(tag, in: file.metadata.tags) == nil, !changes.contains(where: { $0.tag == tag })
    else { return nil }
    let written = changes.first { $0.tag == .field(.albumArtist) }
    guard let albumArtist = written.map(\.new) ?? file.metadata.tags.albumArtist else {
        return nil
    }
    return TagChange(
        id: TagChange.ID(fileID: file.id, tag: tag), field: .albumArtist, current: nil,
        new: albumArtist)
}

/// The tags `target` gets for `value`, each with its text; nil text removes a numbered key the
/// release has no value for.
private func written(
    _ field: DiscogsField, _ value: MappedValue, _ format: DiscogsFieldFormat,
    _ target: DiscogsTarget, format tagFormat: TagFormat, fields: ReleaseFields,
    place: ReleaseFields.Place?, tags: TrackTags
) -> [(MappedTag, String?)] {
    if let template = format.template {
        return [(target.tag(in: tagFormat), filled(template, format, tagFormat, fields, place))]
    }
    guard target.isNumbered else {
        return render(field, value, format, tagFormat).map { [(target.tag(in: tagFormat), $0)] }
            ?? []
    }
    let values = value.values(format, tagFormat: tagFormat)
    var pairs: [(MappedTag, String?)] = values.enumerated().compactMap { index, text in
        target.tag(in: tagFormat, value: index).map { ($0, text) }
    }
    // A numbered key past the release's values is left from another release.
    if case .custom(let first)? = target.tag(in: tagFormat, value: 1) {
        let prefix = String(first.uppercased().dropLast())
        for name in tags.custom.keys.sorted() where name.hasPrefix(prefix) {
            guard let number = Int(name.dropFirst(prefix.count)), number > values.count else {
                continue
            }
            pairs.append((.custom(String(first.dropLast()) + String(number)), nil))
        }
    }
    return pairs
}

/// A field's value as one text, with a date cut to what the rule's format asks.
private func render(
    _ field: DiscogsField, _ value: MappedValue, _ format: DiscogsFieldFormat,
    _ tagFormat: TagFormat
) -> String? {
    guard field == .date, case .text(let date) = value else {
        return value.text(format, tagFormat: tagFormat)
    }
    // No tag format reads a day or month of 00, and ID3v2.3 can't hold a month alone, so a
    // date Discogs knows only in part is its year.
    return format.date == .year || date.contains("-00") ? String(date.prefix(4)) : date
}

/// `template` with each field's token replaced by its value in `format`, and the first genre's
/// by that alone; a field with no value leaves its token empty.
private func filled(
    _ template: String, _ format: DiscogsFieldFormat, _ tagFormat: TagFormat,
    _ fields: ReleaseFields, _ place: ReleaseFields.Place?
) -> String? {
    var text = template.replacingOccurrences(
        of: DiscogsField.firstGenreToken, with: fields.release.genres.first ?? "")
    var tokenFormat = format
    tokenFormat.template = nil
    for field in DiscogsField.allCases where text.contains(field.token) {
        let value = fields.value(field, at: place).flatMap {
            render(field, $0, tokenFormat, tagFormat)
        }
        text = text.replacingOccurrences(of: field.token, with: value ?? "")
    }
    return text.isEmpty ? nil : text
}

/// The text `tag` holds in `tags`, as the editor shows it; nil when it's empty.
private func text(_ tag: MappedTag, in tags: TrackTags) -> String? {
    switch tag {
    case .custom(let name): return tags.custom[name.uppercased()]
    case .field(let field):
        if let property = field.textField?.textProperty { return tags[keyPath: property] }
        if let property = field.numberProperty { return tags[keyPath: property].map(String.init) }
        return tags.compilation ? "1" : "0"
    }
}
