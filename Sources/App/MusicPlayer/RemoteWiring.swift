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
    /// Off, nothing listens or advertises, and every connection is closed.
    func applyRemoteSetting() {
        remote.service?.stop()
        remote.service = nil
        remote.paths?.cancel()
        remote.paths = nil
        guard let settings, settings[\.remoteEnabled], let devices = remoteDeviceRegistry() else {
            return
        }
        guard let identity = remoteIdentity() else {
            browser?.report("The web remote can't start: the Mac has no computer name")
            return
        }
        guard
            let url = Bundle.main.url(
                forResource: "index.html", withExtension: nil, subdirectory: "Remote")
        else {
            browser?.report("The web remote can't start: its page isn't in the app")
            return
        }
        let page: Data
        do {
            page = try Data(contentsOf: url)
        } catch {
            browser?.report("The web remote can't read its page: \(error)")
            return
        }
        let service = RemoteService(
            identity: identity, port: UInt16(settings[\.remotePort]), devices: devices,
            page: Array(page),
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
        remote.service = service
        let paths = NWPathMonitor()
        paths.pathUpdateHandler = { [weak self, weak service] _ in
            Task { @MainActor in
                guard let service, self?.remote.service === service else { return }
                self?.followInterfaces(service)
            }
        }
        paths.start(queue: .main)
        remote.paths = paths
        followInterfaces(service)
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

    /// Starts the service again on the interfaces the Mac has now, when they changed.
    private func followInterfaces(_ service: RemoteService) {
        let interfaces: [NetworkInterface]
        do {
            interfaces = try currentInterfaces()
        } catch {
            browser?.report("The web remote can't read the network interfaces: \(error)")
            return
        }
        Task { [weak self] in
            do {
                try await service.follow(interfaces)
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
        let receiverState = receiver.map(\.state).map { said in
            RemoteState.Receiver(
                isOn: said.isOn, volumeDecibels: said.volume?.decibels, isMuted: said.isMuted,
                input: said.input?.rawValue)
        }
        let output = outputOptionsNow().first { $0.choice == currentOutput }.map {
            RemoteState.Output(choice: $0.choice.text, name: $0.title)
        }
        return RemoteState(
            identity: identity, playback: state, position: position,
            readAt: Date().timeIntervalSince1970, track: remoteTrack(state),
            queue: remote.queue, volumeDecibels: canSetVolume ? volumeDecibels : nil,
            output: output, receiver: receiverState)
    }

    /// The current track's IDs and tags from the index, looked up once per track rather than
    /// at every read of the state.
    private func remoteTrack(_ state: PlaybackState) -> RemoteState.Track? {
        guard let path = state.currentIndex.map({ state.queue[$0].path }) else { return nil }
        if let cached = remote.track, cached.path == path { return cached.track }
        var track: RemoteState.Track?
        do {
            track = try trackLookup?(path).map { row in
                RemoteState.Track(
                    id: row.id, albumID: row.albumID, title: row.title, artist: row.artist,
                    album: row.album, durationSeconds: state.durationSeconds ?? row.durationSeconds)
            }
        } catch {
            logger.error("couldn't look up \(path) for the remote: \(error)")
        }
        remote.track = (path, track)
        return track
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
    /// The current track as the state names it, by its path.
    var track: (path: String, track: RemoteState.Track?)?
}
