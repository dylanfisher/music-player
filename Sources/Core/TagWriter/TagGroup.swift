import Metadata

/// Fields that formats store together, so a writer replaces them as one: a track number and its
/// total share ID3's `TRCK` and MP4's `trkn`.
enum TagGroup: Hashable, CaseIterable {
    /// A field of plain text.
    case text(TagField)
    case track, disc, movement
    case compilation, bpm
    /// A key no field maps, by its name as the edit or the file spells it (ADR 0129): a Vorbis
    /// comment, a `TXXX` or an iTunes freeform item of that name, compared uppercased.
    case custom(String)

    /// The fields' groups; a custom key's isn't among them.
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
        case .custom: []
        }
    }

    /// The custom key's name, uppercased, as keys are compared; nil for a field's group.
    var customKey: String? { customName?.uppercased() }

    /// The custom key's name as spelled, which a writer writes; nil for a field's group.
    var customName: String? {
        if case .custom(let name) = self { name } else { nil }
    }

    /// The custom key `name`'s group; nil for no name, which no format can hold.
    static func custom(named name: String) -> TagGroup? { name.isEmpty ? nil : .custom(name) }

    /// Whether an edit of `group` replaces what this group holds: the same field, or a custom
    /// key of the same name in any case.
    func isReplaced(by group: TagGroup) -> Bool {
        customKey.map { $0 == group.customKey } ?? (self == group)
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
        case .custom: []
        }
    }

    /// The text a single-valued group holds in `tags`; nil when it's empty.
    func text(in tags: TrackTags) -> String? {
        switch self {
        case .text(let field): field.textProperty.flatMap { tags[keyPath: $0] }
        case .compilation: tags.compilation ? "1" : nil
        case .bpm: tags.bpm.map(String.init)
        case .custom: tags.custom[customKey!]
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

    /// The groups whose values differ between `old` and `new`, among those `edit` names: the
    /// fields' in their order, then the custom keys' by name.
    static func changed(by edit: TagEdit, from old: TrackTags, to new: TrackTags) -> [TagGroup] {
        let fields = allCases.filter { group in
            group.fields.contains { edit.values[$0] != nil }
        }
        let custom = edit.custom.keys.compactMap(custom(named:)).sorted {
            $0.customKey! < $1.customKey!
        }
        return (fields + custom).filter { !$0.same(old, new) }
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
