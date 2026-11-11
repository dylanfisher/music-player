import LocalNetwork
import Metadata
import Playback
import UPnP

/// Why a renderer couldn't play a track, or stopped playing one.
public enum RendererOutputError: PlaybackFailure {
    /// The renderer has no AVTransport the app can reach.
    case cannotPlay(renderer: String, String)
    /// No renderer with the UDN answered; `found` names those that did.
    case notFound(udn: String, found: [String])
    case unreadable(MetadataError)
    /// The renderer's sink lists none of the types the file's container is sent as. The file
    /// isn't transcoded.
    case unsupported(format: String, renderer: String, accepts: [String])
    /// The HTTP server the renderer fetches from didn't start.
    case server(LocalNetworkError)
    /// An action failed; the renderer is still there.
    case refused(renderer: String, String)
    /// The renderer stopped before it played the track, as one does with a stream it can't
    /// decode.
    case stoppedWithoutPlaying(renderer: String, contentType: String)
    /// After Play, it stayed transitioning, or in a state the app doesn't know, and never
    /// said it was playing.
    case didNotStart(renderer: String)
    /// It reported `ERROR_OCCURRED`.
    case transportError(renderer: String)
    /// Its remote, front panel or another app stopped it, or gave it another stream.
    case stoppedOnRenderer(renderer: String)
    case playingSomethingElse(renderer: String)

    public var description: String {
        switch self {
        case .cannotPlay(let renderer, let why): "\(renderer) can't be played to: \(why)"
        case .notFound(let udn, let found):
            "no renderer \(udn) answered on the local network; "
                + (found.isEmpty ? "none did" : "these did: \(found.joined(separator: ", "))")
        case .unreadable(let error): "\(error)"
        case .unsupported(let format, let renderer, let accepts):
            "\(renderer) doesn't take \(format) files; it takes "
                + RendererChoice.takes(accepts)
        case .server(let error): "the server the renderer plays from didn't start: \(error)"
        case .refused(let renderer, let problem): "\(renderer): \(problem)"
        case .stoppedWithoutPlaying(let renderer, let type):
            "\(renderer) stopped without playing the track; it may not decode \(type) as sent"
        case .didNotStart(let renderer): "\(renderer) never started playing the track"
        case .transportError(let renderer): "\(renderer) reported an error playing the track"
        case .stoppedOnRenderer(let renderer): "playback was stopped on \(renderer)"
        case .playingSomethingElse(let renderer):
            "\(renderer) is playing something else, so the app stopped sending to it"
        }
    }

    public var userMessage: String {
        switch self {
        case .cannotPlay(let renderer, _): "\(renderer) can't be played to"
        case .notFound: "the renderer didn't answer on the local network"
        case .unreadable(let error): error.userMessage
        case .server: "the app couldn't start sending files to the renderer"
        case .refused(let renderer, _): "\(renderer) refused what the app asked of it"
        case .unsupported, .stoppedWithoutPlaying, .didNotStart, .transportError,
            .stoppedOnRenderer, .playingSomethingElse:
            description
        }
    }
}
