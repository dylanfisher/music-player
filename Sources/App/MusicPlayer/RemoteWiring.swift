import Commands
import Foundation
import LocalNetwork
import Log
import Network
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
        guard
            let url = Bundle.main.url(
                forResource: "index.html", withExtension: nil, subdirectory: "Remote")
        else {
            browser?.report("The web remote can't start: its page isn't in the app")
            return nil
        }
        let page: Data
        do {
            page = try Data(contentsOf: url)
        } catch {
            browser?.report("The web remote can't read its page: \(error)")
            return nil
        }
        return RemoteService(
            identity: identity, devices: devices, page: Array(page),
            state: { [weak self] in
                await self?.remoteState(identity)
                    ?? RemoteState(
                        identity: identity, playback: PlaybackState(), position: nil,
                        readAt: Date().timeIntervalSince1970, track: nil, queue: RemoteQueueStamp(),
                        volumeDecibels: nil, output: nil, receiver: nil)
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
                        album: row.album, durationSeconds: row.durationSeconds)
                }
            }
        } catch {
            logger.error("couldn't look up the playing track for the remote: \(error)")
        }
        return RemoteState(
            identity: identity, playback: state, position: position,
            readAt: Date().timeIntervalSince1970, track: track, queue: remote.queue,
            volumeDecibels: canSetVolume ? volumeDecibels : nil,
            output: RemoteState.Output(current: currentOutput, among: outputOptionsNow()),
            receiver: receiver.map { RemoteState.Receiver($0.state) })
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
}
