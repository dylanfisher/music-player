import AppKit
import Commands
import DiscogsTagger
import Downloads
import Foundation
import Library
import LibraryBrowser
import Metadata
import Recommender
import Settings

/// Soulseek downloads (phase 54): File > Downloads… opens the window, and the downloads run
/// from launch to quit while the service's address and token are set. The import's trash, its
/// stats carried by the watcher and its rescan are wired here, and Open in Tagger opens a
/// Discogs tagger on the staged job.
extension AppDelegate {
    func registerDownloadsCommands(_ dispatcher: CommandDispatcher) {
        dispatcher.handle(
            .showDownloads, enabled: { [weak self] in self?.window != nil },
            run: { [weak self] in self?.downloads.show(offeringSelection: true) })
    }

    /// The settings the downloads are made from; a change to any restarts them.
    static func downloadsKeys(_ schema: AppSettings) -> Set<String> {
        [
            schema.recommenderAddress.key, schema.recommenderPort.key,
            schema.recommenderToken.key, schema.stagingFolder.key, schema.libraryFolder.key,
            schema.discogsCatalogPath.key, schema.discogsMapping.key,
        ]
    }

    /// Starts the downloads when the service's address and token are set, and stops them when
    /// either is cleared.
    func applyDownloadsSettings() {
        downloadsStarting?.cancel()
        downloadsStarting = nil
        guard let settings, downloadsAreSet(settings) else { return downloads.stop() }
        let database = libraryFileURL(in: paths.dataDirectory)
        // The name comes from the index, which is read off the main thread.
        downloadsStarting = Task { [weak self] in
            let machine: String
            do {
                machine = try await Downloads.machineName(databaseURL: database)
            } catch {
                guard !Task.isCancelled else { return }
                self?.fail("Downloads can't start", error)
                return
            }
            guard !Task.isCancelled, let self, let settings = self.settings,
                let setup = downloadsSetup(settings, machine: machine)
            else { return }
            downloads.start(setup)
        }
    }

    private func downloadsAreSet(_ settings: ConfigStore<AppSettings>) -> Bool {
        settings[\.recommenderAddress]?.address != nil && settings[\.recommenderToken] != nil
    }

    func makeDownloads() -> Downloads {
        let downloads = Downloads()
        downloads.selectedTracks = { [weak self] in try self?.browser?.selectedTrackIDs() ?? [] }
        if let state { downloads.columnWidths = state[\.downloadsColumns] }
        downloads.columnWidthsChanged = { [weak self] in self?.saver?.set(\.downloadsColumns, $0) }
        downloads.openInTagger = { [weak self] job, stagingRoot, resolved in
            guard let self, let settings else { return }
            stagedTagger?.window?.close()
            let tagger = DiscogsTagger(
                stagedJob: job, stagingRoot: stagingRoot, dataDirectory: paths.dataDirectory,
                catalog: paths.discogsCatalogFile(settings[\.discogsCatalogPath]),
                mapping: settings[\.discogsMapping],
                savedMappings: settings[\.discogsSavedMappings], choices: taggerChoices(settings),
                resolved: { verdict in resolved(verdict, job.releaseID) })
            stagedTagger = tagger
            tagger.show()
        }
        return downloads
    }

    /// What the downloads are made from, or nil while the service's address or token isn't
    /// set.
    private func downloadsSetup(_ settings: ConfigStore<AppSettings>, machine: String)
        -> Downloads.Setup?
    {
        guard let address = settings[\.recommenderAddress]?.address,
            let token = settings[\.recommenderToken]
        else { return nil }
        let port = UInt16(settings[\.recommenderPort])
        let staging = settings[\.stagingFolder]
        let libraryFolder = settings[\.libraryFolder]
        return Downloads.Setup(
            machine: machine,
            service: DownloadsService(machine: machine) {
                () throws(RecommenderError) in
                try RecommenderClient(address: address, port: port, token: token)
            },
            databaseURL: libraryFileURL(in: paths.dataDirectory),
            dataDirectory: paths.dataDirectory,
            catalog: paths.discogsCatalogFile(settings[\.discogsCatalogPath]),
            mapping: settings[\.discogsMapping], share: staging?.share,
            places: { try await importPlaces(staging: staging, libraryFolder: libraryFolder) },
            trash: { urls in await moveToTrash(urls).failure },
            carry: { [weak self] lines in
                guard let watcher = await self?.watcher else {
                    throw DownloadsSetupProblem("the library isn't watched, so no stats moved")
                }
                return try await watcher.importMoves(lines: lines)
            },
            rescan: { [weak self] directories in
                Task { @MainActor in self?.watcher?.rescan(directories: directories) }
            })
    }
}

/// Where the staging folder and the library folder are now, and the mount point of their
/// share: the staging folder's share when it's on one, else the library folder's volume.
private func importPlaces(staging: StagingFolder?, libraryFolder: String?) async throws
    -> ImportPlaces
{
    guard let staging else { throw DownloadsSetupProblem("no staging folder is set") }
    guard let libraryFolder else { throw DownloadsSetupProblem("no library folder is set") }
    return try await blockingFileWork {
        Result { () throws -> ImportPlaces in
            let shares = staging.share == nil ? [] : try SystemShareMounts().mountedShares()
            guard case .found(let stagingRoot) = locate(staging, among: shares) else {
                throw DownloadsSetupProblem(
                    "the staging folder \(staging.path) isn't mounted, or is in two places")
            }
            let shareRoot: String
            if let share = staging.share {
                guard
                    case .found(let root) = locate(
                        StagingFolder(path: "", share: share), among: shares)
                else { throw DownloadsSetupProblem("the share \(share) isn't mounted") }
                shareRoot = root
            } else {
                let volume = try URL(fileURLWithPath: libraryFolder, isDirectory: true)
                    .resourceValues(forKeys: [.volumeURLKey]).volume
                guard let volume else {
                    throw DownloadsSetupProblem("the library folder's volume wasn't found")
                }
                shareRoot = volume.path
            }
            return ImportPlaces(
                stagingRoot: stagingRoot, libraryFolder: libraryFolder, shareRoot: shareRoot)
        }
    }.get()
}

/// Why the downloads couldn't find what they need.
struct DownloadsSetupProblem: Error, CustomStringConvertible {
    var description: String

    init(_ description: String) { self.description = description }
}
