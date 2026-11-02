import AppKit
import ApplicationServices

/// Takes the keyboard's volume and mute keys away from the system while it exists, and hands
/// each press to `handler` on the main queue. A session event tap, which macOS allows only to
/// an app the owner has given Accessibility permission; without it there's no tap. The tap's
/// callback decodes and returns at once: the handler always runs later, so a slow handler
/// can't make the system disable the tap.
@MainActor
public final class MediaKeyTap {
    /// Whether the owner has given the app Accessibility permission, which the tap needs.
    public static var isPermitted: Bool { AXIsProcessTrusted() }

    /// Asks the system to show its Accessibility prompt, which also lists the app in System
    /// Settings for the owner to switch on.
    public static func askForPermission() {
        // The value of `kAXTrustedCheckOptionPrompt`, a global Swift 6 won't read.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    private let box: TapBox
    private let source: CFRunLoopSource

    /// Nil when the system refuses the tap, as it does without Accessibility permission.
    public init?(handler: @escaping @MainActor (MediaKey) -> Void) {
        let box = TapBox(handler: handler)
        let mask = CGEventMask(1 << NSEvent.EventType.systemDefined.rawValue)
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: mask, callback: mediaKeyCallback,
                userInfo: Unmanaged.passUnretained(box).toOpaque()),
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        else { return nil }
        box.tap = tap
        self.box = box
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Gives the keys back to the system. Call it before letting the tap go.
    public func stop() {
        if let tap = box.tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        box.tap = nil
    }
}

/// What the C callback reaches through its user info pointer.
private final class TapBox {
    let handler: @MainActor (MediaKey) -> Void
    var tap: CFMachPort?

    init(handler: @escaping @MainActor (MediaKey) -> Void) { self.handler = handler }
}

/// Runs on the main run loop for every system-defined event: sound keys are swallowed and
/// their presses handed on, everything else goes through untouched.
private func mediaKeyCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let box = Unmanaged<TapBox>.fromOpaque(userInfo).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        // The system turns a slow tap off; this one never blocks, so it's turned back on.
        if let tap = box.tap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    guard type.rawValue == NSEvent.EventType.systemDefined.rawValue,
        let ns = NSEvent(cgEvent: event)
    else { return Unmanaged.passUnretained(event) }
    let subtype = Int(ns.subtype.rawValue)
    guard MediaKey.isSoundKey(subtype: subtype, data1: ns.data1) else {
        return Unmanaged.passUnretained(event)
    }
    if let key = MediaKey(subtype: subtype, data1: ns.data1) {
        let handler = box.handler
        DispatchQueue.main.async { MainActor.assumeIsolated { handler(key) } }
    }
    return nil
}
