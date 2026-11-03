import AppKit

/// The stall log's name for an event type. Only the type: the keys typed stay out of the log.
func eventName(_ type: NSEvent.EventType) -> String {
    switch type {
    case .keyDown: "key down"
    case .keyUp: "key up"
    case .flagsChanged: "modifier keys"
    case .leftMouseDown, .rightMouseDown, .otherMouseDown: "mouse down"
    case .leftMouseUp, .rightMouseUp, .otherMouseUp: "mouse up"
    case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: "mouse drag"
    case .mouseMoved, .mouseEntered, .mouseExited: "mouse move"
    case .scrollWheel: "scroll"
    case .magnify, .swipe, .rotate, .gesture, .beginGesture, .endGesture, .smartMagnify:
        "gesture"
    case .systemDefined: "system (media key)"
    default: "event type \(type.rawValue)"
    }
}
