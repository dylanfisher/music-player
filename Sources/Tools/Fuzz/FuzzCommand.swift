/// The tool's modes and flags, which the supervisor also passes to the workers and replays it
/// starts.
enum FuzzMode: String {
    case list = "--list"
    case run, worker, replay
}

enum FuzzFlag {
    static let output = "--output"
    static let clones = "--clones"
    static let seed = "--seed"
    static let until = "--until"
}
