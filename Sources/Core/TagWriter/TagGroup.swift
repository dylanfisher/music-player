import Metadata

/// Fields that formats store together, so a writer replaces them as one: a track number and its
/// total share ID3's `TRCK` and MP4's `trkn`.
enum TagGroup: Hashable, CaseIterable {
    /// A field of plain text.
    case text(TagField)
    case track, disc, movement
    case compilation, bpm

    static let allCases: [TagGroup] =
        TagEditField.allCases.compactMap(\.textField).map(TagGroup.text)
        + [.track, .disc, .movement, .compilation, .bpm]

    var fields: [TagEditField] {
        switch self {
        case .text(let field): TagEditField.allCases.filter { $0.textField == field }
        case .track: [.trackNumber, .trackTotal]
        case .disc: [.discNumber, .discTotal]
        case .movement: [.movementNumber, .movementTotal]
        case .compilation: [.compilation]
        case .bpm: [.bpm]
        }
    }

    /// The reader's fields, whose keys in each format are the ones this group replaces. A pair's
    /// number comes first, then its total.
    var readerFields: [TagField] {
        switch self {
        case .text(let field): [field]
        case .track: [.track, .trackTotal]
        case .disc: [.disc, .discTotal]
        case .movement: [.movement, .movementTotal]
        case .compilation: [.compilation]
        case .bpm: [.bpm]
        }
    }

    /// The text a single-valued group holds in `tags`; nil when it's empty.
    func text(in tags: TrackTags) -> String? {
        switch self {
        case .text(let field): field.textProperty.flatMap { tags[keyPath: $0] }
        case .compilation: tags.compilation ? "1" : nil
        case .bpm: tags.bpm.map(String.init)
        case .track, .disc, .movement:
            preconditionFailure("\(self) holds a pair; use numbers(in:)")
        }
    }

    /// A number and its total, for `.track`, `.disc` and `.movement`.
    func numbers(in tags: TrackTags) -> (number: Int?, total: Int?) {
        switch self {
        case .track: (tags.trackNumber, tags.trackTotal)
        case .disc: (tags.discNumber, tags.discTotal)
        case .movement: (tags.movementNumber, tags.movementTotal)
        default: preconditionFailure("\(self) holds one value; use text(in:)")
        }
    }

    var isPair: Bool { self == .track || self == .disc || self == .movement }

    func same(_ a: TrackTags, _ b: TrackTags) -> Bool {
        isPair ? numbers(in: a) == numbers(in: b) : text(in: a) == text(in: b)
    }

    /// The group one of whose reader fields `matches`: the group a format's key belongs to.
    static func of(matching matches: (TagField) -> Bool) -> TagGroup? {
        allCases.first { $0.readerFields.contains(where: matches) }
    }

    /// The groups whose values differ between `old` and `new`, among those `edit` names.
    static func changed(by edit: TagEdit, from old: TrackTags, to new: TrackTags) -> [TagGroup] {
        allCases.filter { group in
            group.fields.contains { edit.values[$0] != nil } && !group.same(old, new)
        }
    }
}

/// "3", "3/12", or "0/12" when only the total is set, as ID3 and Vorbis write a number pair.
func numberPairText(_ pair: (number: Int?, total: Int?)) -> String? {
    switch pair {
    case (nil, nil): nil
    case (let number?, nil): "\(number)"
    case (let number, let total?): "\(number ?? 0)/\(total)"
    }
}
