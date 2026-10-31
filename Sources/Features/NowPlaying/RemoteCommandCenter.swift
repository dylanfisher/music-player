/// The system's remote commands, as `MPRemoteCommandCenter` has them, so tests can use a fake.
@MainActor
public protocol RemoteCommandCenter: AnyObject {
    /// Sends every remote command to `handler` from now on. It returns whether the command ran.
    func start(_ handler: @escaping @MainActor @Sendable (RemoteAction) -> Bool)
    /// Turns on the commands in `enabled` and turns off the rest.
    func setEnabled(_ enabled: Set<RemoteCommand>)
}
