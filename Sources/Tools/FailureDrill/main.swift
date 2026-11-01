import Foundation

// Drives the Core APIs the way the app does, for scripts/kill-test and scripts/full-disk
// (ADR 0023). It reads and writes only under ~/Library/Caches/MusicPlayer and the temp
// directory, never /Volumes or the app's real files:
//   FailureDrill tag-files --fixtures <folder>
// prints fixture files the tag writer can edit and undo, one per line, for cloning.
//   FailureDrill run <operation> --home <folder> --scan <folder> --tags <folder>
// runs a scan, a tag write and its undo, a playlist edit or a state save over and over, until
// killed. Operations: scan, tag-write, playlist-edit, state-save. --scan is a fixture library,
// --tags the clones the tag writer edits.
//   FailureDrill verify --home <folder>
// reopens everything as the app does after a kill: the database passes `PRAGMA
// integrity_check`, the config and state files decode, and every journaled tag edit undoes.
//   FailureDrill full-disk --mount <folder> --scan <folder> --tags <folder>
// fills the disk image at <mount> under the database, the state file, the config file and the
// tag journal in turn, and checks each failure is reported and nothing else changed.
let arguments = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

do {
    let command = try DrillCommand(arguments)
    switch command {
    case .tagFiles(let fixtures):
        for path in try editableFixtureFiles(in: fixtures) { print(path) }
    case .run(let operation, let home, let music):
        try run(operation, home: home, music: music)
    case .verify(let home):
        let failures = try verify(home: home)
        for failure in failures { print("FAILED \(failure)") }
        exit(failures.isEmpty ? 0 : 1)
    case .fullDisk(let mount, let music):
        let failures = try MainActor.assumeIsolated { try fillEachTarget(mount, music: music) }
        for failure in failures { print("FAILED \(failure)") }
        exit(failures.isEmpty ? 0 : 1)
    }
} catch {
    fail("\(error)")
}
