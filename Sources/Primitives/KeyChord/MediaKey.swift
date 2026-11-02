/// A press of one of the keyboard's sound keys, as the system reports it in an
/// `NSSystemDefined` event: subtype 8, with the key and its state packed into `data1`.
public enum MediaKey: Equatable, Sendable {
    case volumeUp, volumeDown, mute

    /// `NSEvent.EventSubtype` 8, the one media keys come as.
    static let auxiliaryControlSubtype = 8

    /// The key a key-down or a repeat stands for; nil for a release, another subtype or
    /// another key, such as play or brightness.
    init?(subtype: Int, data1: Int) {
        guard subtype == Self.auxiliaryControlSubtype, let key = Self.key(data1) else {
            return nil
        }
        // The state sits in bits 8 to 15: 0xA is down, 0xB up.
        guard (data1 & 0xFF00) >> 8 == 0xA else { return nil }
        self = key
    }

    /// Whether `data1` is a sound key at all, down or up, so its release can be held back
    /// with its press.
    static func isSoundKey(subtype: Int, data1: Int) -> Bool {
        subtype == auxiliaryControlSubtype && key(data1) != nil
    }

    /// `NX_KEYTYPE_SOUND_UP`, `NX_KEYTYPE_SOUND_DOWN` and `NX_KEYTYPE_MUTE` from IOKit's
    /// `ev_keymap.h`, in the high 16 bits.
    private static func key(_ data1: Int) -> MediaKey? {
        switch (data1 & 0xFFFF_0000) >> 16 {
        case 0: .volumeUp
        case 1: .volumeDown
        case 7: .mute
        default: nil
        }
    }
}
