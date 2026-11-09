import Foundation
import Metadata
import Settings

/// Settings ▸ Tagging's field mapping as the user edits it, with no AppKit (ADR 0165): the
/// Discogs tagger's mapping in use, a rule for each field, including the parts of a rule the
/// Field Mapping sheet doesn't show, a tag spelled per format or numbered and how each value
/// is written. The draft is checked as the config file's mapping is, and
/// nothing is written until Save.
@MainActor
final class TaggingModel {
    /// The setting the pane edits.
    nonisolated static let setting = AppSettings().discogsMapping
    /// The fields in the order the mapping lists them: the release's, then the track's.
    nonisolated static let fields = DiscogsField.allCases
    /// What the pane says when the file changed while the draft had changes of its own.
    nonisolated static let changedNote = "config.json changed; Revert shows its mapping"

    private let value: (String) -> Any?
    private let set: (String, Any) throws -> Void
    /// Whether the config file refuses every change until it's fixed (ADR 0082).
    let isBlocked: () -> Bool
    /// The mapping as the config file had it when last read or saved.
    private(set) var stored: DiscogsMapping
    var draft: DiscogsMapping
    /// Set when the file changed under an edited draft, until Save or Revert.
    private(set) var note: String?

    /// `value` reads a setting as JSON holds it and `set` writes one, as `GeneralModel`'s do.
    init(
        value: @escaping (String) -> Any?, set: @escaping (String, Any) throws -> Void,
        isBlocked: @escaping () -> Bool
    ) {
        self.value = value
        self.set = set
        self.isBlocked = isBlocked
        stored = Self.read(value)
        draft = stored
    }

    /// The mapping the settings give, which they have already checked.
    private static func read(_ value: (String) -> Any?) -> DiscogsMapping {
        guard let json = value(setting.key) else {
            preconditionFailure("the settings have no \(setting.key)")
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: json, options: .fragmentsAllowed)
            return try setting.value(fromText: String(decoding: data, as: UTF8.self))
        } catch {
            preconditionFailure("the settings' \(setting.key) doesn't read back: \(error)")
        }
    }

    var isEdited: Bool { draft != stored }

    /// Why the config file wouldn't take the draft as its mapping, as it says it; nil when it
    /// would. The draft is written as the file holds it and read back with the same checks.
    var problem: String? {
        do {
            _ = try Self.setting.value(fromText: Self.setting.text(draft))
            return nil
        } catch {
            return "\(error)"
        }
    }

    var canSave: Bool { isEdited && !isBlocked() && problem == nil }

    /// Writes the draft as the mapping in use. Throws why it can't be, leaving the file as
    /// it was.
    func save() throws {
        if let problem {
            throw ConfigProblem(line: nil, message: "\"\(Self.setting.key)\": \(problem)")
        }
        let json = try JSONSerialization.jsonObject(
            with: Data(Self.setting.text(draft).utf8), options: .fragmentsAllowed)
        try set(Self.setting.key, json)
        stored = draft
        note = nil
    }

    /// Puts the file's mapping back in the draft.
    func revert() {
        draft = stored
        note = nil
    }

    /// Reads the mapping again, after the file or the app changed it. A draft without changes
    /// takes the new mapping; one with changes is kept, with a note. While the file is blocked
    /// the settings hold the defaults, not the file's mapping (ADR 0082), so nothing changes.
    func reload() {
        guard !isBlocked() else { return }
        let file = Self.read(value)
        guard file != stored else { return }
        if !isEdited || draft == file {
            draft = file
            note = nil
        } else {
            note = Self.changedNote
        }
        stored = file
    }

    // MARK: A rule

    /// The rule as the table's value column shows it: the mode, the tags, and each part of the
    /// format the rule sets.
    func ruleText(_ field: DiscogsField) -> String {
        let rule = draft[field]
        var parts = [rule.mode.title]
        let tags = rule.targets.map(\.text).joined(separator: ", ")
        if !tags.isEmpty { parts.append(tags) }
        if let join = rule.format.join { parts.append("join “\(join)”") }
        if let template = rule.format.template { parts.append(template) }
        let format = rule.format
        for part in [Part.names, .suffixes, .repeats, .date] where part.isSet(in: format) {
            parts.append(part.choices[part.selected(in: format)])
        }
        if format.credits != nil {
            let styles = TagFormat.allCases.map { format.creditsWritten[$0].title }
            parts.append("credits " + styles.joined(separator: " / "))
        }
        return parts.joined(separator: " · ")
    }

    /// Sets a part of the field's format to its `index`th choice.
    func choose(_ index: Int, of part: Part, for field: DiscogsField) {
        guard part.choices.indices.contains(index), index != part.selected(in: draft[field].format)
        else { return }
        part.set(index, in: &draft[field].format)
    }

    // MARK: The tags

    func tags(_ field: DiscogsField) -> [DiscogsTarget] { draft[field].targets }

    /// Adds a tag with no name yet, which the check refuses until it has one; its position.
    func addTag(for field: DiscogsField) -> Int {
        draft[field].targets.append(.key(""))
        return draft[field].targets.count - 1
    }

    func removeTag(at position: Int, for field: DiscogsField) {
        guard draft[field].targets.indices.contains(position) else { return }
        draft[field].targets.remove(at: position)
    }

    /// Sets how `format` spells the tag at `position`. A name typed for vorbis goes to every
    /// format while they all spell it the same, and numbered keys spelled as the tag is follow
    /// it.
    func setTag(_ text: String, in format: TagFormat, at position: Int, for field: DiscogsField) {
        guard draft[field].targets.indices.contains(position) else { return }
        let target = draft[field].targets[position]
        let old = target.names
        let name = text.trimmingCharacters(in: .whitespaces)
        var names = old
        if format == .vorbis, old.isUniform {
            names = PerTagFormat(name)
        } else {
            names[format] = name
        }
        guard names != old else { return }
        let numbered = target.numberedNames == old ? names : target.numberedNames
        draft[field].targets[position] = DiscogsTarget(names: names, numbered: numbered)
    }

    /// Gives each of a list's values a key of its own, spelled as the tag is, or one key for
    /// them all. A tag whose numbered keys are spelled otherwise keeps them while it stays
    /// numbered.
    func setNumbered(_ on: Bool, at position: Int, for field: DiscogsField) {
        guard draft[field].targets.indices.contains(position) else { return }
        let target = draft[field].targets[position]
        guard on != target.isNumbered else { return }
        draft[field].targets[position] = DiscogsTarget(
            names: target.names, numbered: on ? target.names : nil)
    }

    // MARK: The format

    /// A part of a rule's format with a fixed set of choices, each a pop-up in the pane; the
    /// credits' style is one part per tag format, since YATE writes them differently in each.
    enum Part: Equatable {
        case names, suffixes, repeats, date
        case credits(TagFormat)

        /// The parts in the pane's order.
        static let all = [names, suffixes, repeats, date] + TagFormat.allCases.map(credits)

        var title: String {
            switch self {
            case .names: "Names"
            case .suffixes: "Number Suffixes"
            case .repeats: "Repeated Labels"
            case .date: "Date Written"
            case .credits(let format): "Credits in \(format.rawValue)"
            }
        }

        /// What the part does, for its pop-up's tooltip.
        var help: String {
            switch self {
            case .names: "Which of an artist's names is written"
            case .suffixes:
                "Whether Discogs's number after a name several artists share, as in “Artist (2)”,"
                    + " is kept"
            case .repeats: "Whether a label listed once per catalog number is written each time"
            case .date: "The date in full as Discogs has it, or its year"
            case .credits: "How a credited person is written"
            }
        }

        /// The choices' titles, in the cases' order.
        var choices: [String] {
            switch self {
            case .names: DiscogsFieldFormat.Names.titles
            case .suffixes: DiscogsFieldFormat.Suffixes.titles
            case .repeats: DiscogsFieldFormat.Repeats.titles
            case .date: DiscogsFieldFormat.DateForm.titles
            case .credits: DiscogsFieldFormat.CreditStyle.titles
            }
        }

        /// The choice in effect, a part left out counting as what it writes.
        func selected(in format: DiscogsFieldFormat) -> Int {
            switch self {
            case .names: format.namesWritten.position
            case .suffixes: format.suffixesWritten.position
            case .repeats: format.repeatsWritten.position
            case .date: format.dateWritten.position
            case .credits(let tagFormat): format.creditsWritten[tagFormat].position
            }
        }

        /// Whether the rule's format gives the part, rather than leaving it out.
        func isSet(in format: DiscogsFieldFormat) -> Bool {
            switch self {
            case .names: format.names != nil
            case .suffixes: format.suffixes != nil
            case .repeats: format.repeats != nil
            case .date: format.date != nil
            case .credits: format.credits != nil
            }
        }

        func set(_ index: Int, in format: inout DiscogsFieldFormat) {
            switch self {
            case .names: format.names = .at(index)
            case .suffixes: format.suffixes = .at(index)
            case .repeats: format.repeats = .at(index)
            case .date: format.date = .at(index)
            case .credits(let tagFormat):
                var credits = format.creditsWritten
                credits[tagFormat] = .at(index)
                format.credits = credits
            }
        }
    }
}

/// One of a format part's choices, as its pop-up lists it: the pop-up's index is its place
/// among its cases.
private protocol FormatChoice: CaseIterable, Equatable {
    var title: String { get }
}

extension FormatChoice {
    static var titles: [String] { allCases.map(\.title) }

    /// Its place among its cases, which is its pop-up's index.
    var position: Int { Array(Self.allCases).firstIndex(of: self)! }

    /// The case at `position` among its cases.
    static func at(_ position: Int) -> Self { Array(allCases)[position] }
}

extension DiscogsFieldFormat.Names: FormatChoice {
    var title: String {
        switch self {
        case .canonical: "Discogs Name"
        case .variation: "Name as Credited"
        }
    }
}

extension DiscogsFieldFormat.Suffixes: FormatChoice {
    var title: String {
        switch self {
        case .keep: "Keep “(2)”"
        case .drop: "Drop “(2)”"
        }
    }
}

extension DiscogsFieldFormat.Repeats: FormatChoice {
    var title: String {
        switch self {
        case .keep: "Each Time Listed"
        case .drop: "Once"
        }
    }
}

extension DiscogsFieldFormat.DateForm: FormatChoice {
    var title: String {
        switch self {
        case .full: "Full Date"
        case .year: "Year Only"
        }
    }
}

extension DiscogsFieldFormat.CreditStyle: FormatChoice {
    var title: String {
        switch self {
        case .nameRole: "Name (Role)"
        case .roleNames: "Role;;;Name,Name"
        }
    }
}
