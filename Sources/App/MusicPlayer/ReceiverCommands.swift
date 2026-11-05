import Commands
import KeyChord
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
        applyVolumeKeys()
    }

    /// Starts or stops receiver control as the output moves to or from a Denon receiver,
    /// leaving a running connection alone otherwise.
    func receiverFollowsOutput() {
        guard receiverWanted != (receiver != nil) else { return applyVolumeKeys() }
        applyReceiverSetting()
    }

    /// Takes the Mac's volume and mute keys for the receiver while the app plays to it, and
    /// gives them back otherwise. Without Accessibility permission there's no tap: the system
    /// is asked once a launch to prompt for it, and the keys stay the Mac's.
    func applyVolumeKeys() {
        let wanted = ReceiverControl.takesVolumeKeys(
            setting: settings?[\.receiverVolumeKeys] == true, controlRunning: receiver != nil,
            playingTo: rendererOutput?.renderer)
        guard wanted else {
            volumeKeyTap?.stop()
            volumeKeyTap = nil
            return
        }
        guard volumeKeyTap == nil else { return }
        switch ReceiverControl.volumeKeyAccess(
            permitted: MediaKeyTap.isPermitted,
            promptedBefore: state?[\.askedForAccessibility] == true,
            explainedThisLaunch: explainedAccessibility)
        {
        case .tap: break
        case .prompt:
            do {
                try state?.set(\.askedForAccessibility, to: true)
            } catch {
                logger.error("couldn't record the Accessibility prompt: \(error)")
            }
            MediaKeyTap.askForPermission()
            return
        case .explain:
            explainedAccessibility = true
            browser?.report(ReceiverControl.accessibilityHint)
            return
        case .nothing:
            return
        }
        volumeKeyTap = MediaKeyTap { [weak self] key in
            switch key {
            case .volumeUp: _ = self?.dispatcher?.run(.receiverVolumeUp)
            case .volumeDown: _ = self?.dispatcher?.run(.receiverVolumeDown)
            case .mute: _ = self?.dispatcher?.run(.receiverMute)
            }
        }
        if volumeKeyTap == nil { logger.error("the system refused the volume key tap") }
    }

    private var receiverWanted: Bool {
        ReceiverControl.isWanted(
            enabled: settings?[\.receiverEnabled] == true, playingTo: rendererOutput?.renderer)
    }

    /// Sends the signal path slider's level to the receiver, which says it back in a status
    /// line.
    func slideReceiverVolume(_ decibels: Double) {
        guard let volume = ReceiverVolume(decibels: decibels) else { return }
        receiver?.run(.setVolume(volume))
    }

    /// Shows the receiver's volume in the signal path while it's connected.
    private func receiverChanged(_ control: ReceiverControl) {
        let connected = if case .connected = control.status { true } else { false }
        signalPath?.showReceiver(connected: connected, decibels: control.state.volume?.decibels)
    }

    private func makeReceiverControl() -> ReceiverControl {
        let control = ReceiverControl(
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
        control.changed = { [weak self, weak control] in
            if let control { self?.receiverChanged(control) }
        }
        return control
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
