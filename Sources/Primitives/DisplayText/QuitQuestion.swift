/// What the app asks when the user quits while work is under way: the work, a line each, and
/// what quitting does to it. The app gathers the lines from each feature (ADR 0191).
public struct QuitQuestion: Equatable, Sendable {
    let message: String
    let detail: String

    /// The button that quits with the work cut short, here and in the tag editor's question.
    public static let quitAnyway = "Quit Anyway"

    /// The question about `alsoListing` and `running` together, in that order; nil when
    /// `running` is empty, so work in `alsoListing` alone is left to the question its own
    /// feature asks: the tag writes', which can wait for them (ADR 0167).
    public init?(running: [String], alsoListing: [String] = []) {
        guard !running.isEmpty else { return nil }
        let lines = alsoListing + running
        let one = lines.count == 1
        message = "Quit with work in progress?"
        detail =
            lines.map { "• " + $0 }.joined(separator: "\n")
            + "\n\nQuitting stops \(one ? "it where it is" : "them where they are")."
            + " What \(one ? "it has" : "they have") finished stays done."
    }
}
