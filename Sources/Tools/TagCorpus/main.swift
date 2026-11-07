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
//   TagCorpus --discogs-survey <folder>…
// reads every audio file under the folders, read only, and reports the Discogs tags they carry
// in .build/discogs-survey under the current directory, which is all it writes (ADR 0128).
let arguments = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

do {
    if let problem = argumentProblem(arguments) { fail(problem) }
    if arguments == [pathsFlag] {
        print(referenceCorpusPath)
        print(try cloneFolder().path)
        exit(0)
    }
    if arguments.first == discogsSurveyFlag {
        let folders = arguments.dropFirst().map { URL(fileURLWithPath: $0, isDirectory: true) }
        exit(try discogsSurvey(folders, output: surveyFolder()) == 0 ? 0 : 1)
    }
    guard arguments.first == roundTripFlag else {
        let folder = URL(fileURLWithPath: arguments.first ?? referenceCorpusPath, isDirectory: true)
        exit(try survey(folder) == 0 ? 0 : 1)
    }
    let fullDisk = arguments.firstIndex(of: fullDiskFlag).map {
        URL(fileURLWithPath: arguments[$0 + 1], isDirectory: true)
    }
    var run = try RoundTrip(
        reference: URL(fileURLWithPath: referenceCorpusPath, isDirectory: true),
        clones: try cloneFolder(),
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
