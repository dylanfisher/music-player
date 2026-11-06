import AppKit
import Commands
import Library
import LibraryBrowser
import Log
import Playback
import Scripting
import Settings

private let logger = moduleLogger()

/// The `music-player` tool's socket and `music-player://` links, both run through the
/// registry by `ScriptRouter` (ADR 0036).
extension AppDelegate {
    /// Links that wait for playback to be ready, past which more are refused.
    static let waitingLinksCap = 16

    /// Once playback is ready, so a request that plays finds the engine.
    func startScripting() {
        guard let dispatcher else {
            refuseWaitingLinks()
            return
        }
        let router = ScriptRouter(
            dispatcher: dispatcher,
            status: { [weak self] in
                await self?.scriptStatus()
                    ?? ScriptStatus(PlaybackState(), positionSeconds: nil, track: nil)
            },
            arguments: [
                .play: { [weak self] text in try await self?.playQuery(text) },
                .receiverSetVolume: { [weak self] text in try self?.setReceiverVolume(text) },
            ],
            reports: [
                .showStats: { [weak self] text, _, json in
                    guard let self else { throw NoWindow() }
                    return try await statsReply(text, json: json)
                },
                .showSpectrum: { [weak self] _, paths, json in
                    guard let self else { throw NoWindow() }
                    return try await analysisReply(paths, json: json)
                },
            ])
        scriptRouter = router
        do {
            scriptServer = try startScriptServer(
                path: scriptSocketPath(dataDirectory: paths.dataDirectory), router: router,
                problem: { logger.error("\($0)") })
        } catch {
            browser?.report("\(toolName) can't reach the app: \(error)")
        }
        let links = waitingLinks
        waitingLinks = []
        for link in links { runLink(link) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { runLink(url.absoluteString) }
    }

    private func runLink(_ link: String) {
        guard dispatcher != nil else {
            browser?.report("a \(urlScheme) link didn't run: the app has no commands")
            return
        }
        guard let router = scriptRouter else {
            guard waitingLinks.count < Self.waitingLinksCap else {
                logger.error(
                    "a \(urlScheme) link was dropped: \(Self.waitingLinksCap) already wait")
                return
            }
            waitingLinks.append(link)
            return
        }
        Task {
            if case .failed(let reason) = await router.link(link) {
                browser?.report("a \(urlScheme) link didn't run: \(reason)")
            }
        }
    }

    /// The app couldn't build its commands, so the links that waited for them fail, logged,
    /// since there's no window to show them in.
    private func refuseWaitingLinks() {
        for _ in waitingLinks {
            logger.error("a \(urlScheme) link didn't run: the app has no commands")
        }
        waitingLinks = []
    }

    private func playQuery(_ text: String) async throws -> String {
        guard engine != nil, let browser else { throw NoOutput() }
        return try await browser.play(PlayQuery(text))
    }

    /// Shows Listening Stats for the period `text` names, or the one shown last, and says what
    /// they hold, as `music-player stats` prints it.
    private func statsReply(_ text: String?, json: Bool) async throws -> String {
        guard let browser else { throw NoWindow() }
        let period: StatsPeriod?
        if let text {
            guard let named = StatsPeriod(text: text) else {
                throw InvalidPeriod(text: text)
            }
            period = named
        } else {
            period = nil
        }
        browser.showStats(period)
        return try await browser.statsText(period ?? browser.shownStatsPeriod, json: json)
    }

    private func scriptStatus() async -> ScriptStatus {
        let state = playback
        let position = await engine?.position()
        let track = state.currentIndex.map { state.queue[$0].path }.map { path in
            var row: TrackRow?
            do {
                row = try trackLookup?(path)
            } catch {
                logger.error("couldn't look up \(path) for the status: \(error)")
            }
            return ScriptStatus.Track(
                path: path, title: row?.title, artist: row?.artist, album: row?.album,
                albumArtist: row?.albumArtist,
                durationSeconds: state.durationSeconds ?? row?.durationSeconds)
        }
        return ScriptStatus(state, positionSeconds: position, track: track)
    }
}

/// Play has nothing to play through.
private struct NoOutput: Error, CustomStringConvertible {
    var description: String { "the app has no output device" }
}

/// Stats has no window to read the library through.
private struct NoWindow: Error, CustomStringConvertible {
    var description: String { "the app has no library window" }
}

private struct InvalidPeriod: Error, CustomStringConvertible {
    var text: String
    var description: String { "\(text) isn't a period: \(StatsPeriod.textHelp)" }
}
