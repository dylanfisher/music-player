import Foundation
import Library
import Settings
import TagWriter

/// Runs `operation` over and over until the process is killed, marking each write. Each pass
/// changes what's stored: a scan alternates between two halves of the fixture library, so each
/// one adds half and removes half.
@MainActor
func run(_ operation: DrillOperation, home: URL, music: MusicFolders) throws -> Never {
    let paths = AppPaths(home: home)
    let databaseURL = libraryFileURL(in: paths.dataDirectory)
    var pass = 0
    switch operation {
    case .scan:
        let scanner = LibraryScanner(databaseURL: databaseURL)
        while true {
            let half = pass % 2 == 0 ? evenTracks : oddTracks
            let folder = WatchedFolder(path: music.scan.path, kind: .local, exclude: [half])
            let summary = try marked { try scanner.scan(folder) }
            guard summary.issues.isEmpty else {
                throw DrillError("the scan reported \(summary.issues)")
            }
            pass += 1
        }
    case .tagWrite:
        let writer = TagWriter(journal: TagUndoJournal(dataDirectory: paths.dataDirectory))
        let files = try audioFiles(in: music.tags)
        guard !files.isEmpty else { throw DrillError("no files to edit in \(music.tags.path)") }
        while true {
            let written = marked {
                writer.write(TagEdit(values: [.title: "\(drillTitle) \(pass)"]), to: files)
            }
            guard written.failures.isEmpty, written.changed.count == files.count else {
                throw DrillError("the write reported \(written)")
            }
            let undone = marked { writer.undoLast() }
            guard undone.failures.isEmpty, undone.changed.count == files.count else {
                throw DrillError("the undo reported \(undone)")
            }
            pass += 1
        }
    case .playlistEdit:
        let index = try LibraryIndex(at: databaseURL)
        if try index.trackCount() == 0 {
            _ = try LibraryScanner(databaseURL: databaseURL).scan(
                WatchedFolder(path: music.scan.path, kind: .local))
        }
        let tracks = try index.trackIDs(sortedBy: .path)
        while true {
            try marked {
                let id = try index.createPlaylist(named: "\(drillTitle) \(pass)")
                _ = try index.addToPlaylist(id, trackIDs: tracks)
                try index.movePlaylistEntries(
                    id, trackIDs: Array(tracks.suffix(tracks.count / 2)), before: tracks.first)
                try index.removeFromPlaylist(id, trackIDs: Array(tracks.prefix(tracks.count / 3)))
                try index.setRating(pass % 6, trackIDs: tracks)
                try index.renamePlaylist(id, to: "\(drillTitle) \(pass) renamed")
                // Keeps a few, so the database holds playlists across kills.
                if pass >= 3 {
                    let playlists = try index.playlists()
                    try index.deletePlaylist(playlists.first { $0.id != id }!.id)
                }
            }
            pass += 1
        }
    case .stateSave:
        let state = try StateStore(AppState(), fileURL: paths.stateFile)
        while true {
            try marked {
                try state.set(
                    \.sidebarWidth, to: AppState.sidebarWidthRange.lowerBound + pass % 400)
            }
            try marked {
                try state.set(\.queueWidth, to: AppState.queueWidthRange.lowerBound + pass % 700)
            }
            pass += 1
        }
    case .configSave:
        let config = ConfigStore(
            AppSettings(), fileURL: paths.configFile, check: acceptingEveryShortcut, creating: true)
        while true {
            try marked { try config.set(\.hogMode, to: pass % 2 == 0) }
            if let failure = config.writeFailure {
                throw DrillError("the config write failed: \(failure)")
            }
            pass += 1
        }
    }
}

/// The drill writes no shortcuts, so it has no registry to check them against.
let acceptingEveryShortcut: ShortcutCheck = { _, _, _ in nil }

/// The audio files directly in `folder`, by path; hidden ones, such as a tag writer's temp
/// file, are left out.
func audioFiles(in folder: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: folder.path)
        .filter { !$0.hasPrefix(".") }.sorted().map { folder.appendingPathComponent($0).path }
}
