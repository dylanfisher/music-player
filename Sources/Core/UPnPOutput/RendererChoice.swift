import UPnP

/// Finding the renderer `output.renderer` names, and listing the ones found.
public enum RendererChoice {
    /// The renderer whose UDN is `udn` among those discovery found; throws, naming the ones
    /// that did answer, when it isn't one of them.
    public static func renderer(_ udn: String, in found: [Renderer]) throws(RendererOutputError)
        -> Renderer
    {
        guard let renderer = found.first(where: { $0.udn == udn }) else {
            throw .notFound(udn: udn, found: found.map { "\($0.name) (\($0.udn))" })
        }
        return renderer
    }

    /// One line per renderer for `--list-devices`: its name, model, address and UDN, then what
    /// it takes, or why it can't be played to.
    public static func report(_ renderers: [Renderer]) -> String {
        guard !renderers.isEmpty else { return "No UPnP renderers answered on the local network." }
        return
            (["UPnP renderers, by the UDN output.renderer takes:"]
            + renderers.map { renderer in
                let what =
                    renderer.transportProblem.map { "can't be played to: \($0)" }
                    ?? renderer.formatsProblem.map { "its formats weren't read: \($0)" }
                    ?? "takes \(takes(renderer.httpAudioTypes))"
                return "  \(renderer.name) (\(renderer.model)) at \(renderer.address), "
                    + "\(renderer.udn): \(what)"
            }).joined(separator: "\n")
    }

    /// The audio types a renderer takes over HTTP, as a list for a sentence.
    static func takes(_ types: [String]) -> String {
        types.isEmpty ? "no audio over HTTP" : types.joined(separator: ", ")
    }
}
