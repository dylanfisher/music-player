import Commands
import Foundation
import Library
import LocalNetwork
import Log
import Network
import NowPlaying
import Playback
import Remote
import Scripting
import Settings
import SystemConfiguration

private let logger = moduleLogger()

/// The web remote's wiring (ADR 0214): the settings that start and stop it, what its state
/// reads, its commands through the router, and the interfaces it follows.
extension AppDelegate {
    /// Starts the remote when `remote.enabled` is on, on `remote.port`, and stops it otherwise.
    /// Off, nothing listens or advertises, and every connection is closed. One service is made
    /// for the launch, so its starts and stops run in order (ADR 0214).
    func applyRemoteSetting() {
        guard let settings, settings[\.remoteEnabled] else {
            remote.service?.stop()
            remote.paths?.cancel()
            remote.paths = nil
            return
        }
        guard let service = remote.service ?? makeRemoteService() else { return }
        remote.service = service
        if remote.paths == nil {
            let paths = NWPathMonitor()
            paths.pathUpdateHandler = { [weak self] _ in
                Task { @MainActor in
                    guard self?.settings?[\.remoteEnabled] == true else { return }
                    self?.followInterfaces()
                }
            }
            paths.start(queue: .main)
            remote.paths = paths
        }
        followInterfaces()
    }

    private func makeRemoteService() -> RemoteService? {
        guard let devices = remoteDeviceRegistry() else { return nil }
        guard let identity = remoteIdentity() else {
            browser?.report("The web remote can't start: the Mac has no computer name")
            return nil
        }
        guard let folder = Bundle.main.url(forResource: "Remote", withExtension: nil) else {
            browser?.report("The web remote can't start: its page isn't in the app")
            return nil
        }
        let page: RemotePage
        do {
            page = try RemotePage(folder: folder)
        } catch {
            browser?.report("The web remote can't start: \(error)")
            return nil
        }
        guard let library = remoteLibrary() else { return nil }
        return RemoteService(
            identity: identity, devices: devices, page: page, library: library,
            state: { [weak self] in
                await self?.remoteState(identity)
                    ?? RemoteState(
                        identity: identity, playback: PlaybackState(), position: nil,
                        readAt: Date().timeIntervalSince1970, track: nil, queue: RemoteQueueStamp(),
                        volumeDecibels: nil, output: nil, receiver: nil)
            },
            queue: { [weak self] in
                await self?.remoteQueue() ?? RemoteQueue(stamp: 0, paths: [], position: nil)
            },
            run: { [weak self] id, argument in
                await self?.runFromRemote(id, argument) ?? .failed("the app is quitting")
            },
            advertiser: DNSServiceAdvertiser(), browser: NetworkBrowser(),
            problem: { logger.notice("\($0)") }, pairing: remote.pairing)
    }

    /// The paired devices, read from the state file once and kept for the launch, so the
    /// Settings window can forget one while the remote is off.
    func remoteDeviceRegistry() -> RemoteDeviceRegistry? {
        if let devices = remote.devices { return devices }
        guard let state else { return nil }
        let made = RemoteDeviceRegistry(
            state[\.remoteDevices], save: { try state.set(\.remoteDevices, to: $0) })
        remote.devices = made
        return made
    }

    /// The remote's library reads, made on first use and kept for the launch, which Play
    /// Tracks and Queue Tracks resolve through whether the remote is on or not.
    private func remoteLibrary() -> RemoteLibrary? {
        if let library = remote.library { return library }
        guard let settings else { return nil }
        let made = RemoteLibrary(
            databaseURL: libraryFileURL(in: paths.dataDirectory), thumbnails: thumbnails,
            groupByAlbumArtist: settings[\.groupByAlbumArtist])
        remote.library = made
        return made
    }

    /// Play Tracks' or, `queueing`, Queue Tracks' argument, from the remote or the command line.
    func playTracks(_ text: String, queueing: Bool) async throws -> String? {
        guard let library = remoteLibrary() else { throw RemoteNotReady() }
        let files = try await library.files(argument: text, queueing: queueing)
        if queueing { addToQueue(files.urls) } else { play(files.urls, first: files.first) }
        return nil
    }

    /// Play List's argument, from the remote or the command line.
    func playList(_ text: String) async throws -> String? {
        guard let library = remoteLibrary() else { throw RemoteNotReady() }
        let files = try await library.files(list: text)
        play(files.urls, first: files.first)
        return nil
    }

    /// Move in Queue's (`moving`) or Remove from Queue at's argument.
    func editQueue(_ text: String, moving: Bool) async throws -> String? {
        guard let engine else { throw RemoteNotReady() }
        let asked = try remote.queue.edit(text, moving: moving)
        // The engine checks the queue and edits it in one step, so it can't change between.
        guard await engine.edit(asked.edit, ifQueueIs: asked.queue, order: asked.order) else {
            throw RemoteRefusal.queueChanged
        }
        return nil
    }

    /// The queue in play order, as `/api/queue` reads it.
    private func remoteQueue() -> RemoteQueue {
        let state = playback
        return RemoteQueue(
            stamp: remote.queue.stamp, paths: state.order.map { state.queue[$0].path },
            position: state.currentIndex.flatMap { state.order.firstIndex(of: $0) })
    }

    /// Starts the service on the interfaces the Mac has now and `remote.port`, unless it runs
    /// on just those.
    private func followInterfaces() {
        guard let service = remote.service, let settings else { return }
        let port = UInt16(settings[\.remotePort])
        let interfaces: [NetworkInterface]
        do {
            interfaces = try currentInterfaces()
        } catch {
            browser?.report("The web remote can't read the network interfaces: \(error)")
            return
        }
        Task { [weak self] in
            do {
                try await service.follow(interfaces, port: port)
            } catch {
                self?.browser?.report("The web remote can't listen: \(error)")
            }
        }
    }

    /// This Mac as the remote names it: the ID in the state file, made once, and the
    /// computer's names. Nil when the system has no names for it.
    private func remoteIdentity() -> RemoteService.Identity? {
        guard let state,
            let name = SCDynamicStoreCopyComputerName(nil, nil) as String?,
            let host = SCDynamicStoreCopyLocalHostName(nil) as String?
        else { return nil }
        var id = state[\.remoteInstanceID] ?? ""
        if !RemoteService.isInstanceID(id) {
            id = RemoteService.newInstanceID()
            do {
                try state.set(\.remoteInstanceID, to: id)
            } catch {
                logger.error("couldn't save the remote's instance ID, so it changes: \(error)")
            }
        }
        return RemoteService.Identity(id: id, name: name, host: host)
    }

    private func runFromRemote(_ id: CommandID, _ argument: String?) async -> ScriptReply {
        guard let scriptRouter else { return .failed("the app's commands aren't ready yet") }
        return await scriptRouter.handle(.run(id, argument: argument), from: .remote)
    }

    /// What's playing now, as the remote's state and events say it.
    private func remoteState(_ identity: RemoteService.Identity) async -> RemoteState {
        let position = await engine?.position()
        let state = playback
        var track: RemoteState.Track?
        do {
            track = try remote.track.track(at: state.currentIndex.map { state.queue[$0].path }) {
                [trackLookup] path in
                try trackLookup?(path).map { row in
                    RemoteState.Track(
                        id: row.id, albumID: row.albumID, title: row.title, artist: row.artist,
                        album: row.album, durationSeconds: row.durationSeconds,
                        art: RemoteLibrary.artID(row))
                }
            }
        } catch {
            logger.error("couldn't look up the playing track for the remote: \(error)")
        }
        return RemoteState(
            identity: identity, playback: state, position: position,
            readAt: Date().timeIntervalSince1970, track: track, queue: remote.queue,
            volumeDecibels: canSetVolume ? volumeDecibels : nil,
            volumeFloorDecibels: MainToolbar.volumeRangeDecibels.lowerBound,
            output: RemoteState.Output(current: currentOutput, among: outputOptionsNow()),
            receiver: receiver.map {
                RemoteState.Receiver(
                    $0.state, volumeRangeDecibels: SignalPathPanel.receiverRangeDecibels)
            })
    }
}

/// The web remote's parts the app keeps, touched only on the main actor.
@MainActor
final class RemoteParts {
    /// While `remote.enabled` is on.
    var service: RemoteService?
    /// Restarts the service on the interfaces the Mac has as they change.
    var paths: NWPathMonitor?
    /// What the state says of the queue and of when this Mac last played.
    var queue = RemoteQueueStamp()
    /// The code, kept while the remote is off so the Settings window reads one place.
    let pairing = RemotePairing()
    /// The paired devices, made from the state file on first use.
    var devices: RemoteDeviceRegistry?
    /// The current track as the state names it.
    var track = RemoteTrackCache()
    /// The library's reads for the remote and its track commands, made on first use.
    var library: RemoteLibrary?
}

/// A track or queue command came before the app had its library or engine.
private struct RemoteNotReady: Error, CustomStringConvertible {
    var description: String { "the app's library and playback aren't ready yet" }
}
