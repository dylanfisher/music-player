import Commands
import LocalNetwork
import Log
import Receiver
import Settings
import UPnP

private let logger = moduleLogger()

/// Receiver control's wiring: the setting that starts and stops it, the registry's receiver
/// commands, and where its problems are shown (ADR 0039).
extension AppDelegate {
    /// Starts receiver control when `receiver.enabled` is on or the app plays to a Denon
    /// receiver, and stops it otherwise. Off, nothing is sent onto the network.
    func applyReceiverSetting() {
        receiver = ReceiverControl.applying(
            enabled: receiverWanted, to: receiver, make: makeReceiverControl)
    }

    /// Starts or stops receiver control as the output moves to or from a Denon receiver,
    /// leaving a running connection alone otherwise.
    func receiverFollowsOutput() {
        guard receiverWanted != (receiver != nil) else { return }
        applyReceiverSetting()
    }

    private var receiverWanted: Bool {
        ReceiverControl.isWanted(
            enabled: settings?[\.receiverEnabled] == true, playingTo: rendererOutput?.renderer)
    }

    private func makeReceiverControl() -> ReceiverControl {
        ReceiverControl(
            discover: {
                try await RendererDiscovery.discover(
                    transport: UDPSearchTransport(
                        destination: SSDPSearch.multicastGroup, port: SSDPSearch.port),
                    subnets: LocalSubnets(try currentInterfaces()))
            },
            fallback: { [weak self] in self?.settings?[\.receiverAddress]?.address },
            interfaces: { try currentInterfaces() },
            problem: { [weak self] problem in
                switch problem {
                case .unreachable: self?.browser?.report("\(problem)")
                case .ignored: logger.notice("\(problem)")
                }
            })
    }

    func registerReceiverCommands(_ dispatcher: CommandDispatcher) {
        // On whenever receiver control is: a command with no connection searches again.
        let found: () -> Bool = { [weak self] in self?.receiver != nil }
        func handle(
            _ id: CommandID, isOn: ((ReceiverState) -> Bool)? = nil,
            sends command: @escaping (ReceiverState) -> ReceiverCommand
        ) {
            dispatcher.handle(
                id, enabled: found,
                isOn: isOn.map { isOn in
                    { [weak self] in self?.receiver.map { isOn($0.state) } ?? false }
                },
                run: { [weak self] in
                    guard let receiver = self?.receiver else { return }
                    receiver.run(command(receiver.state))
                })
        }
        handle(.receiverVolumeUp, sends: { _ in .volumeUp })
        handle(.receiverVolumeDown, sends: { _ in .volumeDown })
        handle(.receiverMute, isOn: { $0.isMuted == true }, sends: { .mute($0.isMuted != true) })
        handle(.receiverPowerOn, isOn: { $0.isOn == true }, sends: { _ in .power(true) })
        handle(.receiverStandby, isOn: { $0.isOn == false }, sends: { _ in .power(false) })
        for mode in ReceiverSoundMode.allCases {
            handle(
                .receiverSoundMode(mode), isOn: { $0.isIn(mode) }, sends: { _ in .soundMode(mode) })
        }
        for input in ReceiverInput.allCases {
            handle(
                .receiverInput(input), isOn: { $0.input == input }, sends: { _ in .input(input) })
        }
        // It needs a level, which only the command line passes, so it's in no menu.
        dispatcher.handle(.receiverSetVolume, enabled: { false }, run: {})
    }

    /// Set Receiver Volume's argument, from the command line.
    func setReceiverVolume(_ text: String) throws -> String? {
        guard let volume = ReceiverVolume(decibels: text) else {
            throw ReceiverVolume.Refusal(text: text)
        }
        guard let receiver else {
            throw ReceiverControl.Problem.unreachable("receiver control is off")
        }
        receiver.run(.setVolume(volume))
        return nil
    }
}
