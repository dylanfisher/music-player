import KeyChord
import Log

private let logger = moduleLogger()

/// Runs commands by ID, and decides what a key press does. The menus, the focused list's keys and
/// the palette all come here, so a command runs one way whichever way it was chosen.
@MainActor
public final class CommandDispatcher {
    /// What became of a key press.
    public enum KeyOutcome: Equatable {
        case ran
        /// A command has the chord but is off now; the caller beeps.
        case refused
        /// No command has the chord.
        case unbound
    }

    private struct Handler {
        var run: () -> Void
        var isEnabled: () -> Bool
        var isOn: (() -> Bool)?
        var isMixed: (() -> Bool)?
        var title: (() -> String)?
    }

    public private(set) var bindings: KeyBindings
    /// Called after the bindings change, so the menus show the new chords.
    public var bindingsChanged: () -> Void = {}
    /// Called before any command runs: the stall detector notes it.
    public var willRun: (CommandID) -> Void = { _ in }
    private var handlers: [CommandID: Handler] = [:]

    public init(bindings: KeyBindings) {
        self.bindings = bindings
    }

    public func setBindings(_ bindings: KeyBindings) {
        self.bindings = bindings
        for dropped in bindings.dropped { logger.notice("shortcut dropped: \(dropped)") }
        bindingsChanged()
    }

    /// `run` does the command; `enabled` says whether it can now; `isOn` gives a toggle its
    /// check mark; `isMixed` gives it the mixed mark instead, for a choice the things it acts
    /// on differ in; `title` names it as it would run now, in the menus and the palette.
    public func handle(
        _ id: CommandID, enabled: @escaping () -> Bool = { true }, isOn: (() -> Bool)? = nil,
        isMixed: (() -> Bool)? = nil, title: (() -> String)? = nil, run: @escaping () -> Void
    ) {
        precondition(bindings.defaults.command(id) != nil, "\(id) isn't a registered command")
        precondition(handlers[id] == nil, "\(id) has two handlers")
        handlers[id] = Handler(
            run: run, isEnabled: enabled, isOn: isOn, isMixed: isMixed, title: title)
    }

    public func isEnabled(_ id: CommandID) -> Bool { handlers[id]?.isEnabled() ?? false }

    /// Nil for a command that isn't a toggle.
    public func isOn(_ id: CommandID) -> Bool? { handlers[id]?.isOn?() }

    /// Whether the command shows the mixed mark now; false for one that has none.
    public func isMixed(_ id: CommandID) -> Bool { handlers[id]?.isMixed?() == true }

    /// The title the command has now; nil for one whose title is always its registered one.
    public func title(_ id: CommandID) -> String? { handlers[id]?.title?() }

    /// Runs the command if it's on now; false when it's off or has no handler.
    @discardableResult
    public func run(_ id: CommandID) -> Bool {
        guard let handler = handlers[id], handler.isEnabled() else { return false }
        willRun(id)
        handler.run()
        return true
    }

    /// Runs the command bound to the first of `chords` that has one, the spellings a key press
    /// can mean.
    public func key(_ chords: [KeyChord]) -> KeyOutcome {
        guard let id = chords.lazy.compactMap({ self.bindings.registry.command(for: $0) }).first
        else { return .unbound }
        return run(id) ? .ran : .refused
    }
}
