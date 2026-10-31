import Foundation

// The tag writer's real-world test, on the owner's reference corpus (ADR 0020):
//   TagCorpus [<folder>]
// lists every file's tag layout, read only, from the reference corpus or <folder>.
//   TagCorpus --round-trip [--full-disk <mount point>]
// edits and undoes every clone in ~/Library/Caches/MusicPlayer/tag-corpus, which
// scripts/tag-corpus has just made from the reference, then injects failures; --full-disk is a
// small disk image attached inside the clone folder. It writes nowhere else.
//   TagCorpus --paths
// prints the reference folder and the clone folder, one per line, for scripts/tag-corpus.
let arguments = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

do {
    if let problem = argumentProblem(arguments) { fail(problem) }
    if arguments == ["--paths"] {
        print(referenceCorpusPath)
        print(try cloneFolder().path)
        exit(0)
    }
    guard arguments.first == "--round-trip" else {
        let folder = URL(fileURLWithPath: arguments.first ?? referenceCorpusPath)
        exit(try survey(folder) == 0 ? 0 : 1)
    }
    let fullDisk = arguments.firstIndex(of: "--full-disk").map {
        URL(fileURLWithPath: arguments[$0 + 1])
    }
    var run = try RoundTrip(
        reference: URL(fileURLWithPath: referenceCorpusPath), clones: try cloneFolder(),
        fullDisk: fullDisk)
    let started = Date()
    try run.run()
    print("files \(run.files), edits \(run.edits), failures \(run.failures.count)")
    print(String(format: "took %.0f s", Date().timeIntervalSince(started)))
    if !run.unreadByAVFoundation.isEmpty {
        print(
            "AVFoundation reads no metadata from: \(run.unreadByAVFoundation.sorted().joined(separator: ", "))"
        )
    }
    for failure in run.failures { print("FAILED \(failure)") }
    exit(run.failures.isEmpty ? 0 : 1)
} catch {
    fail("\(error)")
}

/// Why `arguments` can't run, or nil.
func argumentProblem(_ arguments: [String]) -> String? {
    if let unknown = arguments.first(where: {
        $0.hasPrefix("--") && !["--round-trip", "--full-disk", "--paths"].contains($0)
    }) {
        return "\(unknown) isn't an option"
    }
    if let index = arguments.firstIndex(of: "--full-disk") {
        guard arguments.first == "--round-trip" else {
            return "--full-disk only goes with --round-trip"
        }
        guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
            return "--full-disk needs a mount point"
        }
        guard arguments.count == 3 else { return "--round-trip takes only --full-disk" }
        return nil
    }
    if arguments.contains("--paths") {
        return arguments.count == 1 ? nil : "--paths takes nothing else"
    }
    if arguments.first == "--round-trip" {
        return arguments.count == 1 ? nil : "--round-trip takes only --full-disk"
    }
    return arguments.count <= 1 ? nil : "takes at most one folder"
}
