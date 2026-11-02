import Fixtures
import Foundation

// Builds the fixture library later phases test and benchmark against:
//   GenerateFixtures [--count <files>] [--output <directory>] [--force]
let arguments = CommandLine.arguments

func value(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
        return nil
    }
    return arguments[index + 1]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

var count = fullLibraryFileCount
if let text = value(after: "--count") {
    guard let parsed = Int(text), parsed > 0 else {
        fail("--count takes a positive number of files, not \"\(text)\"")
    }
    count = parsed
}

do {
    let root =
        try value(after: "--output").map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? defaultFixturesDirectory()
    let start = Date()
    let outcome = try generateFixtures(
        count: count, in: root, force: arguments.contains("--force"))
    let seconds = String(format: "%.1f", Date().timeIntervalSince(start))
    switch outcome {
    case .generated: print("wrote \(count) files to \(root.path) in \(seconds) s")
    case .upToDate: print("\(root.path) already holds \(count) files (checked in \(seconds) s)")
    }
} catch {
    fail("\(error)")
}
