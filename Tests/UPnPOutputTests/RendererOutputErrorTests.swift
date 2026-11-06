import LocalNetwork
import Metadata
import Testing

@testable import Fixtures
@testable import UPnPOutput

/// One of each case, so a case added without a message for people shows here.
private let errors: [RendererOutputError] = [
    .cannotPlay(renderer: "Denon", "its AVTransport has no controlURL"),
    .notFound(udn: "uuid:5f9ec1b3", found: ["Sonos"]),
    .unreadable(MetadataError(unreadable: "/m/a.flac", detail: "no such file")),
    .unsupported(format: "AIFF (PCM)", renderer: "Denon", accepts: ["audio/flac"]),
    .server(.system("bind", errno: 48)),
    .refused(renderer: "Denon", "SOAP fault 701: Transition not available"),
    .stoppedWithoutPlaying(renderer: "Denon", contentType: "audio/flac"),
    .transportError(renderer: "Denon"), .stoppedOnRenderer(renderer: "Denon"),
    .playingSomethingElse(renderer: "Denon"),
]

@Test func everyRendererErrorHasAPlainMessage() {
    for error in errors {
        #expect(readsAsPlainText(error.userMessage), "\(error): \(error.userMessage)")
    }
}
