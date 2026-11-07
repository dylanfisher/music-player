let roundTripFlag = "--round-trip"
let fullDiskFlag = "--full-disk"
let pathsFlag = "--paths"
let discogsSurveyFlag = "--discogs-survey"

/// Why `arguments` can't run, or nil.
func argumentProblem(_ arguments: [String]) -> String? {
    let roundTripTakes = "\(roundTripFlag) takes only \(fullDiskFlag)"
    if let unknown = arguments.first(where: {
        $0.hasPrefix("--")
            && ![roundTripFlag, fullDiskFlag, pathsFlag, discogsSurveyFlag].contains($0)
    }) {
        return "\(unknown) isn't an option"
    }
    if let index = arguments.firstIndex(of: discogsSurveyFlag) {
        guard index == 0 else { return "\(discogsSurveyFlag) goes first" }
        return arguments.count > 1 ? nil : "\(discogsSurveyFlag) needs at least one folder"
    }
    if let index = arguments.firstIndex(of: fullDiskFlag) {
        guard arguments.first == roundTripFlag else {
            return "\(fullDiskFlag) only goes with \(roundTripFlag)"
        }
        guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
            return "\(fullDiskFlag) needs a mount point"
        }
        return arguments.count == 3 ? nil : roundTripTakes
    }
    if arguments.contains(pathsFlag) {
        return arguments.count == 1 ? nil : "\(pathsFlag) takes nothing else"
    }
    if arguments.first == roundTripFlag { return arguments.count == 1 ? nil : roundTripTakes }
    return arguments.count <= 1 ? nil : "takes at most one folder"
}
