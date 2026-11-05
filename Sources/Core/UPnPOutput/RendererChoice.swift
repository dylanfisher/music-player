import UPnP

/// Finding the renderer `output.renderer` names, and listing the ones found.
public enum RendererChoice {
    /// The renderer whose UDN is `udn` among those discovery found; throws, naming the ones
    /// that did answer, when it isn't one of them. A Sonos player that has joined another's
    /// group since it was picked gives way to that group's coordinator, which plays for it.
    public static func renderer(_ udn: String, in found: [Renderer]) throws(RendererOutputError)
        -> Renderer
    {
        guard let renderer = found.first(where: { $0.udn == udn }) else {
            throw .notFound(udn: udn, found: found.map { "\($0.name) (\($0.udn))" })
        }
        return coordinator(of: renderer, in: found) ?? renderer
    }

    /// The renderers the output picker offers: each Sonos group once, by its coordinator and
    /// its name, and everything else as found. A member stays when its coordinator didn't
    /// answer, so the group can still be picked.
    public static func choices(_ found: [Renderer]) -> [Renderer] {
        found.filter { coordinator(of: $0, in: found) == nil }
    }

    private static func coordinator(of renderer: Renderer, in found: [Renderer]) -> Renderer? {
        guard renderer.isGroupMember, let leader = renderer.sonos?.coordinator else { return nil }
        return found.first { $0.sonos?.playerID == leader }
    }

    /// `--list-devices`'s renderers, or why the search for them failed: the devices are
    /// listed already, so a failed search is a note, not a failure.
    public static func listing(_ search: Result<[Renderer], any Error>) -> String {
        switch search {
        case .success(let renderers): report(renderers)
        case .failure(let error): "The network search for UPnP renderers failed: \(error)"
        }
    }

    /// One line per renderer: its name, model, address and UDN, then what it takes, or why it
    /// can't be played to.
    static func report(_ renderers: [Renderer]) -> String {
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
