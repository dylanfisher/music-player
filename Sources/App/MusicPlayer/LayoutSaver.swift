import Foundation
import Log
import Settings

private let logger = moduleLogger()

/// Saves window layout changes to the state file, coalesced: a drag of a divider or a column edge
/// reports every step, and each save rewrites the file.
@MainActor
final class LayoutSaver {
    /// How long after the last change the file is written.
    static let delaySeconds = 1.0

    private let settings: StateStore<AppState>
    /// The latest value of each changed setting, by key, as a write to run.
    private var pending: [String: () throws -> Void] = [:]
    private var scheduled = false
    /// Why the last flush couldn't save, until one saves everything it had.
    private(set) var failure: String?
    /// Called when `failure` changes, for the banner.
    var failureChanged: () -> Void = {}

    init(_ settings: StateStore<AppState>) {
        self.settings = settings
    }

    func set<Value>(_ setting: KeyPath<AppState, Setting<Value>>, _ value: Value) {
        let settings = settings
        pending[settings.schema[keyPath: setting].key] = { try settings.set(setting, to: value) }
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delaySeconds) { [weak self] in
            self?.flush()
        }
    }

    /// Writes everything pending now, as the app quits.
    func flush() {
        scheduled = false
        let writes = pending
        pending = [:]
        guard !writes.isEmpty else { return }
        var failures: [String] = []
        for (key, write) in writes.sorted(by: { $0.key < $1.key }) {
            do {
                try write()
            } catch {
                logger.error("couldn't save \(key): \(error)")
                failures.append("\(key): \(error)")
            }
        }
        let next = failures.isEmpty ? nil : failures.joined(separator: "; ")
        guard next != failure else { return }
        failure = next
        failureChanged()
    }
}
