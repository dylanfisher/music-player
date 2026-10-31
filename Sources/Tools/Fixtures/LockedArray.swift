import Foundation

/// An array that `DispatchQueue.concurrentPerform` iterations can each write their own slot of.
final class LockedArray<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element]

    init(repeating value: Element, count: Int) {
        storage = Array(repeating: value, count: count)
    }

    subscript(index: Int) -> Element {
        get { lock.withLock { storage[index] } }
        set { lock.withLock { storage[index] = newValue } }
    }

    var values: [Element] { lock.withLock { storage } }
}
