import Settings
import TagWriter

/// The Field Mapping sheet's mapping as the user edits it, with no AppKit (ADR 0132): a rule
/// per field, a preset to start from, and the user's own saved by name. Nothing is saved until
/// the sheet's OK.
struct MappingDraft: Equatable {
    var mapping: DiscogsMapping {
        didSet { note = nil }
    }
    var saved: [NamedDiscogsMapping]
    /// The name last chosen or saved, which the draft is while its mapping is that one's.
    private var name: String?
    /// What the last Save As did, until the mapping changes: "Saved as “Mine”".
    private(set) var note: String?

    init(mapping: DiscogsMapping, saved: [NamedDiscogsMapping]) {
        self.mapping = mapping
        self.saved = saved
    }

    /// The presets, then the user's.
    var choices: [NamedDiscogsMapping] { DiscogsPreset.all + saved }

    /// The preset or saved mapping the draft is, if it's one: the one last chosen or saved
    /// when it still is, as two can hold the same mapping.
    var chosenName: String? {
        if let name, choices.contains(where: { $0.name == name && $0.mapping == mapping }) {
            return name
        }
        return choices.first { $0.mapping == mapping }?.name
    }

    mutating func use(_ name: String) {
        guard let chosen = choices.first(where: { $0.name == name }) else { return }
        mapping = chosen.mapping
        self.name = name
    }

    /// Why the mapping can't be used, as the settings check says; nil when it can.
    var problem: String? { mapping.problem() }

    /// The targets as the sheet's text shows them: field names and keys, comma-separated.
    func targetsText(_ field: DiscogsField) -> String {
        mapping[field].targets.map { target in
            switch target {
            case .field(let tag): tag.rawValue
            case .key(let names, nil) where names.isUniform: names.vorbis
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
                numbered == nil && names.isUniform
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
            return DiscogsTarget(names: PerTagFormat(name))
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

    /// The mapping as Export… writes it: as the config file holds its mapping, one encoder for
    /// both.
    var exported: String { AppSettings().discogsMapping.text(mapping) }

    /// Shows the mapping `text` holds, unsaved, from Import… or Paste, `source` saying which.
    /// The problem when the config file wouldn't take it as its mapping, leaving the draft as
    /// it was.
    mutating func load(_ text: String, from source: String) -> String? {
        let loaded: DiscogsMapping
        do {
            loaded = try AppSettings().discogsMapping.value(fromText: text)
        } catch {
            return error.description
        }
        mapping = loaded
        name = nil
        note = "\(source), not saved; Save As keeps it"
        return nil
    }

    /// Whether Save As `name` would replace a saved mapping, which the sheet asks about first.
    func replaces(_ name: String) -> Bool {
        saved.contains { $0.name == name.trimmingCharacters(in: .whitespaces) }
    }

    /// Saves the draft under `name`, replacing a saved one of that name, and chooses it; the
    /// problem when the name or the mapping can't be saved.
    mutating func save(as name: String) -> String? {
        let named = NamedDiscogsMapping(
            name: name.trimmingCharacters(in: .whitespaces), mapping: mapping)
        if let problem = named.problem() { return problem }
        saved.removeAll { $0.name == named.name }
        saved.append(named)
        self.name = named.name
        note = "Saved as “\(named.name)”"
        return nil
    }

    /// Whether `name` is one of the user's saved mappings, which Remove can take out; a
    /// preset can't be.
    func isSaved(_ name: String) -> Bool { saved.contains { $0.name == name } }

    /// Takes the saved mapping `name` out of the list, leaving the mapping shown as it is.
    mutating func remove(_ name: String) {
        guard isSaved(name) else { return }
        saved.removeAll { $0.name == name }
        if self.name == name { self.name = nil }
        note = "Removed “\(name)”; OK keeps the change"
    }
}
