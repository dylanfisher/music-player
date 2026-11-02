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
    /// Starts receiver control when `receiver.enabled` is on and stops it when it's off. Off,
    /// nothing is sent onto the network.
    func applyReceiverSetting() {
        guard let settings, settings[\.receiverEnabled] else {
            receiver?.stop()
            receiver = nil
            return
        }
        let made = receiver ?? makeReceiverControl()
        receiver = made
        made.start()
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
        let found: () -> Bool = { [weak self] in self?.receiver?.hasReceiver == true }
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
        // It needs a level, which only the command line passes (`receiverVolumeArgument`).
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
