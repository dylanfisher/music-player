import Foundation

/// Whether a message for the user reads as plain text: not empty, and with nothing that looks
/// like a type name (`DeviceOutputError`, `ExtAudioFileOpenURL`) or a code (`'typ?'`, `0x1f`,
/// `(-50)`, `kAudio_`). "DoP" and "DSD64" pass.
func readsAsPlainText(_ message: String) -> Bool {
    !message.isEmpty
        && message.range(of: "[A-Z][a-z]+[A-Z][a-z]", options: .regularExpression) == nil
        && message.range(of: "'[!-~]{4}'|0x|\\(-?[0-9]+\\)|_|Error", options: .regularExpression)
            == nil
}
