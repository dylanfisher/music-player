import Foundation

// The tag writer's real-world test, on the owner's reference corpus (ADR 0020):
//   TagCorpus [<folder>]
// lists every file's tag layout, read only.
let arguments = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

do {
    guard arguments.count <= 1 else { fail("takes at most one folder") }
    let folder = URL(fileURLWithPath: arguments.first ?? referenceCorpusPath)
    exit(try survey(folder) == 0 ? 0 : 1)
} catch {
    fail("\(error)")
}
