import CoreAudio
import Foundation
import Log

private let logger = moduleLogger()

/// One property of one HAL object.
struct PropertyKey: Hashable {
    var object: AudioObjectID
    var selector: AudioObjectPropertySelector
    var scope: AudioObjectPropertyScope
    var element: AudioObjectPropertyElement

    init(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) {
        self.object = object
        self.selector = selector
        self.scope = scope
        self.element = element
    }

    var address: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }
}

/// Adds and removes HAL property listeners: CoreAudio in the app, a recorder in tests.
protocol PropertyListening {
    func add(
        _ key: PropertyKey, _ queue: DispatchQueue,
        _ block: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus
    func remove(
        _ key: PropertyKey, _ queue: DispatchQueue,
        _ block: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus
}

struct HALPropertyListening: PropertyListening {
    func add(
        _ key: PropertyKey, _ queue: DispatchQueue,
        _ block: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus {
        var address = key.address
        return AudioObjectAddPropertyListenerBlock(key.object, &address, queue, block)
    }

    func remove(
        _ key: PropertyKey, _ queue: DispatchQueue,
        _ block: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus {
        var address = key.address
        return AudioObjectRemovePropertyListenerBlock(key.object, &address, queue, block)
    }
}

/// The listeners one block has, kept equal to the set the caller wants. A device plugged back in
/// gets new object IDs, so following it means removing exactly what was added to the old ones;
/// diffing the sets does that, and `set([])` removes the rest. Not thread-safe.
final class PropertyListeners {
    private let listening: any PropertyListening
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock
    private(set) var active: Set<PropertyKey> = []

    init(
        _ listening: any PropertyListening, queue: DispatchQueue,
        block: @escaping AudioObjectPropertyListenerBlock
    ) {
        self.listening = listening
        self.queue = queue
        self.block = block
    }

    /// A listener that won't add is logged and left out, so the next `set` tries it again.
    func set(_ wanted: Set<PropertyKey>) {
        for key in active.subtracting(wanted) {
            // An object that's gone can refuse the removal; its listeners went with it.
            let status = listening.remove(key, queue, block)
            if status != noErr {
                logger.info(
                    "removing the '\(fourCharCode(key.selector))' listener from \(key.object) failed: \(status)"
                )
            }
            active.remove(key)
        }
        for key in wanted.subtracting(active) {
            let status = listening.add(key, queue, block)
            if status == noErr {
                active.insert(key)
            } else {
                logger.error(
                    "can't listen to '\(fourCharCode(key.selector))' on \(key.object): \(status)")
            }
        }
    }
}
