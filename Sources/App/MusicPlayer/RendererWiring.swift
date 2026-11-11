import Foundation
import LocalNetwork
import Log
import Playback
import UPnP
import UPnPOutput

private let logger = moduleLogger()

/// The UPnP output's wiring: `output.renderer` moves playback to the renderer it names once a
/// search finds it, and back to the device when it's null (ADR 0041).
extension AppDelegate {
    func applyRendererSetting() {
        guard let settings, engine != nil else { return }
        rendererSearch?.cancel()
        rendererSearch = nil
        guard let udn = settings[\.outputRenderer] else { return useDevice() }
        if rendererOutput?.renderer.udn == udn { return }
        logger.notice("searching the local network for the renderer \(udn)")
        rendererSearch = Task { [weak self] in
            let found: Result<Renderer, any Error>
            do {
                found = .success(try RendererChoice.renderer(udn, in: try await searchRenderers()))
            } catch {
                found = .failure(error)
            }
            guard !Task.isCancelled else { return }
            self?.rendererFound(found)
        }
    }

    private func rendererFound(_ found: Result<Renderer, any Error>) {
        guard let engine else { return }
        let output: RendererOutput
        do {
            output = try RendererOutput(
                try found.get(), rediscover: { try await searchRenderers() })
        } catch {
            logger.error("no renderer: \(error)")
            browser?.report("Couldn't play to the network renderer: \(error)")
            return
        }
        let replaced = rendererOutput
        rendererOutput = output
        rendererPathUpdates?.cancel()
        rendererPathUpdates = Task { [weak self] in
            for await path in output.signalPaths { self?.signalPath?.show(path) }
        }
        logger.notice("playing to \(output.renderer.name) at \(output.renderer.address)")
        receiverFollowsOutput()
        Task {
            await engine.use(output)
            replaced?.close()
        }
    }

    private func useDevice() {
        guard let renderer = rendererOutput, let engine, let device = output else { return }
        rendererOutput = nil
        rendererPathUpdates?.cancel()
        rendererPathUpdates = nil
        signalPath?.show(devicePath)
        receiverFollowsOutput()
        Task {
            await engine.use(device)
            renderer.close()
        }
    }
}

/// The MediaRenderers on the local network, from one SSDP search.
func searchRenderers() async throws -> [Renderer] {
    let outcome = try await RendererDiscovery.discover(
        transport: UDPSearchTransport(
            destination: SSDPSearch.multicastGroup, port: SSDPSearch.port),
        subnets: LocalSubnets(try currentInterfaces()))
    for problem in outcome.problems { logger.notice("\(problem)") }
    return outcome.renderers
}

/// `--list-devices`'s second part: the renderers a search finds, which `output.renderer`
/// takes by UDN, or why the search failed.
@MainActor
func rendererListing() -> String {
    print(
        "searching the local network for UPnP renderers, about \(Int(RendererDiscovery.searchSeconds)) s"
    )
    fflush(stdout)
    let done = DispatchSemaphore(value: 0)
    let box = ListingBox()
    // Detached, because the caller runs on the main actor, which the semaphore blocks.
    Task.detached {
        do {
            box.result = .success(try await searchRenderers())
        } catch {
            box.result = .failure(error)
        }
        done.signal()
    }
    done.wait()
    return RendererChoice.listing(box.result)
}

// Written by the task before `done.signal()` and read after `done.wait()`: the semaphore
// orders the handoff.
private final class ListingBox: @unchecked Sendable {
    var result: Result<[Renderer], any Error> = .success([])
}
