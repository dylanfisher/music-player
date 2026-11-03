import AppKit
import Testing

@testable import MusicPlayer

@Test func eventsAreNamedByTypeOnly() {
    #expect(eventName(.keyDown) == "key down")
    #expect(eventName(.otherMouseDragged) == "mouse drag")
    #expect(eventName(.periodic) == "event type \(NSEvent.EventType.periodic.rawValue)")
}
