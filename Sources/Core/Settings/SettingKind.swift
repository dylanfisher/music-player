/// What a setting holds, in enough detail for the settings window to pick a control.
public indirect enum SettingKind: Sendable, Equatable {
    case bool
    /// With the allowed range, when the setting has one.
    case integer(ClosedRange<Int>?)
    case number(ClosedRange<Double>?)
    case string
    /// Text with these tokens in braces.
    case template([Token])
    /// One of these values.
    case choice([Choice])
    /// The value or null.
    case optional(SettingKind)
    case list(SettingKind)
    /// Columns of a bar's parts, which the settings window's bar builder edits.
    case barLayout(Bar)
    case watchedFolder
    case syncFolder
    case dumpsFolder
    /// The Discogs tagger's field mapping, which its own sheet edits (ADR 0132).
    case discogsMapping
    /// A color with its opacity, which the settings window picks in a color well.
    case color
    /// Window layout the app saves as it changes; the settings window shows no control for it.
    case windowState

    public struct Choice: Sendable, Equatable {
        public var rawValue: String
        public var title: String
    }

    public struct Token: Sendable, Equatable {
        /// As a template writes it: `{artist}`.
        public var name: String
        /// What it stands for.
        public var help: String
    }

    /// What the bar builder needs to know about one bar: its parts, and the words and the
    /// height that differ between bars.
    public struct Bar: Sendable, Equatable {
        public var choices: [Choice]
        /// The parts as tall as the bar, by raw value, which stack with no others.
        public var fillsHeight: [String]
        /// The stacking checkbox's title.
        public var stackTitle: String
        /// A sentence saying what the center column does.
        public var centerHelp: String
        /// The tallest the bar grows to fit a stack, in points, or nil when only its parts
        /// limit it.
        public var stackCapPoints: Double?
    }
}
