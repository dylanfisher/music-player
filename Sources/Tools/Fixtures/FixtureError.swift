enum FixtureError: Error, CustomStringConvertible {
    case afconvertFailed(arguments: [String], status: Int32, output: String)
    case unexpectedSeed(String)
    case refusingToClear(path: String)
    case artwork(String)

    var description: String {
        switch self {
        case .afconvertFailed(let arguments, let status, let output):
            "afconvert \(arguments.joined(separator: " ")) exited with \(status): \(output)"
        case .unexpectedSeed(let why): "afconvert wrote a file the generator can't read: \(why)"
        case .artwork(let why): why
        case .refusingToClear(let path):
            "\(path) isn't empty and has no \(FixtureManifest.fileName) from an earlier run;"
                + " pick another directory"
        }
    }
}
