/// Separate Releases set while the app runs, against what the index was built with at launch
/// (ADR 0143): whether to ask, and what the answer does.
struct SeparateReleasesChange: Equatable {
    /// What the window's first open built the index with.
    let inUse: Bool

    enum Answer: Equatable {
        /// Relaunch, with a rescan confirmed for this value.
        case relaunch(Bool)
        /// Set the setting back to the value in use.
        case revert
        /// Nothing: the setting is the value in use again.
        case nothing
    }

    /// Whether the setting at `setting` needs the question.
    func asks(_ setting: Bool) -> Bool { setting != inUse }

    /// What the answer does, from the setting as it is when answered, so a setting changed
    /// back while the question was up neither relaunches nor writes.
    func answer(rescan: Bool, setting: Bool) -> Answer {
        guard asks(setting) else { return .nothing }
        return rescan ? .relaunch(setting) : .revert
    }
}
