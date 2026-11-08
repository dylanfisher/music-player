import Settings
import TagWriter

/// The Field Mapping sheet's mapping as the user edits it, with no AppKit (ADR 0132): a rule
/// per field, a preset to start from, and the user's own saved by name. Nothing is saved until
/// the sheet's OK.
struct MappingDraft: Equatable {
    var mapping: DiscogsMapping
    var saved: [NamedDiscogsMapping]

    /// The presets, then the user's.
    var choices: [NamedDiscogsMapping] { DiscogsPreset.all + saved }

    /// The preset or saved mapping the draft is, if it's one.
    var chosenName: String? { choices.first { $0.mapping == mapping }?.name }

    mutating func use(_ name: String) {
        guard let chosen = choices.first(where: { $0.name == name }) else { return }
        mapping = chosen.mapping
    }

    /// Why the mapping can't be used, as the settings check says; nil when it can.
    var problem: String? { mapping.problem() }

    /// The targets as the sheet's text shows them: field names and keys, comma-separated.
    func targetsText(_ field: DiscogsField) -> String {
        mapping[field].targets.map { target in
            switch target {
            case .field(let tag): tag.rawValue
            case .key(let names, nil) where isOneSpelling(names): names.vorbis
            case .key(let names, let numbered):
                names.vorbis + (numbered == nil ? " (spelled per format)" : " (numbered)")
            }
        }.joined(separator: ", ")
    }

    /// Whether the targets are plain enough to edit as text; a key spelled per format or
    /// numbered is edited in the config file.
    func targetsEditable(_ field: DiscogsField) -> Bool {
        mapping[field].targets.allSatisfy { target in
            if case .key(let names, let numbered) = target {
                numbered == nil && isOneSpelling(names)
            } else {
                true
            }
        }
    }

    /// `text`'s comma-separated names as targets: a tag editor field's name is that field,
    /// anything else a custom key.
    mutating func setTargets(_ text: String, for field: DiscogsField) {
        guard targetsEditable(field) else { return }
        mapping[field].targets = text.split(separator: ",").compactMap { part in
            let name = part.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            return TagEditField(rawValue: name).map(DiscogsTarget.field) ?? .key(name)
        }
    }

    mutating func setMode(_ mode: DiscogsFieldRule.Mode, for field: DiscogsField) {
        mapping[field].mode = mode
    }

    /// Empty text is no join, or no template.
    mutating func setJoin(_ text: String, for field: DiscogsField) {
        mapping[field].format.join = text.isEmpty ? nil : text
    }

    mutating func setTemplate(_ text: String, for field: DiscogsField) {
        mapping[field].format.template = text.isEmpty ? nil : text
    }

    /// Saves the draft under `name`, replacing a saved one of that name; the problem when the
    /// name or the mapping can't be saved.
    mutating func save(as name: String) -> String? {
        let named = NamedDiscogsMapping(
            name: name.trimmingCharacters(in: .whitespaces), mapping: mapping)
        if let problem = named.problem() { return problem }
        saved.removeAll { $0.name == named.name }
        saved.append(named)
        return nil
    }
}

/// Whether every format spells the key the same.
private func isOneSpelling(_ names: PerTagFormat<String>) -> Bool {
    names.vorbis == names.mp4 && names.mp4 == names.id3
}
