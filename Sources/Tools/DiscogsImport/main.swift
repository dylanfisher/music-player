import Discogs
import Foundation
import Library
import Settings

// Imports a Discogs dump set into a catalog, as the Discogs window will (ADR 0130), for the
// real dump's numbers in phase 51:
//   DiscogsImport [<dumps folder>] [--catalog <path>]
// reads the newest complete set in the folder, or in the config file's `discogs.dumpsFolder`,
// into `--catalog`, or the config file's `discogs.catalogPath`, or `discogs.sqlite` in
// Application Support. It refuses a catalog inside a watched folder, prints a progress line
// every `reportSeconds`, and ends with the wall time and the catalog's size. It only reads the
// dumps.
let reportSeconds = 10.0
// A line at a time, as its output goes to a log file while it runs.
setvbuf(stdout, nil, _IOLBF, 0)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

var arguments = Array(CommandLine.arguments.dropFirst())
var catalogArgument: String?
if let flag = arguments.firstIndex(of: "--catalog") {
    guard flag + 1 < arguments.count else { fail("--catalog needs a path") }
    catalogArgument = arguments[flag + 1]
    arguments.removeSubrange(flag...(flag + 1))
}
guard arguments.count <= 1, arguments.first?.hasPrefix("-") != true else {
    fail("usage: DiscogsImport [<dumps folder>] [--catalog <path>]")
}

let paths: AppPaths
let settings: ConfigStore<AppSettings>
let shares: [MountedShare]
do {
    paths = try AppPaths.standard()
    // As the app reads it: unknown keys are skipped with a warning, anything else stops.
    settings = ConfigStore(
        AppSettings(), fileURL: paths.configFile, check: { _, _, _ in nil }, creating: false)
    guard !settings.blocked else {
        fail(
            "\(paths.configFile.path): \(settings.problems.map { "\($0)" }.joined(separator: "; "))"
        )
    }
    for problem in settings.problems {
        FileHandle.standardError.write(Data("warning: \(paths.configFile.path): \(problem)\n".utf8))
    }
    shares = try SystemShareMounts().mountedShares()
} catch {
    fail("\(error)")
}

let dumpsFolder = settings[\.discogsDumpsFolder]
let catalogPath = settings[\.discogsCatalogPath]
let configured = settings[\.watchedFolders]
let folder: URL
if let path = arguments.first {
    folder = URL(fileURLWithPath: path, isDirectory: true)
} else if let dumpsFolder {
    do {
        folder = try locate(dumpsFolder, among: shares)
    } catch {
        fail("\(error)")
    }
} else {
    fail("pass the dumps folder, or set discogs.dumpsFolder in \(paths.configFile.path)")
}
let catalog =
    catalogArgument.map { URL(fileURLWithPath: $0, isDirectory: false) }
    ?? paths.discogsCatalogFile(catalogPath)
// The watched folders where they are now; one on a share that isn't mounted holds nothing.
let watched = configured.compactMap { folder -> String? in
    guard folder.share != nil else { return folder.path }
    if case .found(let path) = Library.locate(
        SyncFolder(path: folder.path, share: folder.share), among: shares)
    {
        return path
    }
    return nil
}

print("importing \(folder.path) into \(catalog.path)")
let started = Date()
let lastPrinted = LockedDate()
let task = Task {
    try await importCatalog(from: folder, to: catalog, outsideOf: watched) { progress in
        guard lastPrinted.elapsed(atLeast: reportSeconds) else { return }
        let seconds = Date().timeIntervalSince(started)
        let rate = Double(progress.bytesRead) / max(seconds, 1) / 1e6
        print(String(format: "%7.0f s  %6.1f MB/s  ", seconds, rate) + progress.text)
    }
}
// Control-C, or `kill -INT`, stops the import the way the window's Stop does.
signal(SIGINT, SIG_IGN)
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interrupt.setEventHandler { task.cancel() }
interrupt.resume()
do {
    let summary = try await task.value
    print(
        String(
            format: "done in %.0f s: the %@ dump, %.1f GB read, catalog %.2f GB",
            summary.seconds, summary.dumpDate, Double(summary.compressedBytes) / 1e9,
            Double(summary.catalogBytes) / 1e9))
    for kind in DumpKind.allCases {
        print("  \(kind.rawValue): \(summary.records[kind] ?? 0)")
    }
} catch CatalogImportError.stopped {
    fail("stopped; the catalog that was there is still in use")
} catch {
    fail("\(error)")
}

/// When a progress line was last printed, read and set from the import's thread.
final class LockedDate: Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var date = Date.distantPast

    /// Whether `seconds` have gone by since it last said so, noting now when they have.
    func elapsed(atLeast seconds: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard Date().timeIntervalSince(date) >= seconds else { return false }
        date = Date()
        return true
    }
}
