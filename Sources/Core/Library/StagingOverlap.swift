import Settings

/// The folder of `folders` that the staging folder at `staging` is in, at or holds, or nil when
/// they're apart. All are paths where the folders are found now: Settings can't compare one
/// stored by share with one stored by path, so the code that uses the staging folder checks
/// again where they are (ADR 0144).
func stagingOverlap(_ staging: String, _ folders: [String]) -> String? {
    folders.first { isPath(staging, inOrAt: $0) || isPath($0, inOrAt: staging) }
}
