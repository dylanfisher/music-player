/// A value a `TokenTemplate` names in braces, as `{artist}`: its raw value is the name.
public protocol TemplateToken: RawRepresentable<String>, CaseIterable, Equatable, Sendable {
    /// What it stands for, as the setting's help lists it.
    var help: String { get }
    /// A template to suggest when one is empty, such as `{title} — {artist}`.
    static var example: String { get }
}

extension TemplateToken {
    /// The token as a template writes it.
    var placeholder: String { "{\(rawValue)}" }
}
