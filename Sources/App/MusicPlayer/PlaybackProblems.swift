import AppKit
import Foundation
import Log
import NowPlaying
import Playback

private let logger = moduleLogger()

/// Where playback problems are explained and fixed: the details window the status bar opens,
/// and the fixes its button and the problem's dialog offer (ADR 0111).
extension AppDelegate {
    func makeProblemWindow() -> PlaybackProblemWindow {
        let window = PlaybackProblemWindow()
        window.fixRequested = { [weak self] in self?.apply($0, for: $1) }
        return window
    }

    /// Opens the details of `shown` with the output's last signal path and, for a device, its
    /// hog mode setting, which the config mirrors from the device in use, or during a fallback
    /// that device's profile.
    func showProblem(_ shown: ShownProblem) {
        let hogMode = settings.flatMap {
            outputFallback.hogModeShown(config: $0[\.hogMode], inUse: inUseProfile?.hogMode)
        }
        problemWindow.show(
            ProblemReport(
                shown, path: signalPath?.path, hogMode: rendererOutput == nil ? hogMode : nil))
    }

    /// Makes `fix` through the settings the user would change, then plays the problem's track
    /// again if it's still the queue's current one, or says why not over the window it was
    /// asked from.
    func apply(_ fix: PlaybackFix, for shown: ShownProblem) {
        switch fix {
        case .turnOnHogMode(let uid):
            // The config's hog mode is the device in use's, so it fixes only that device.
            guard let settings, uid == outputUID, rendererOutput == nil else {
                logger.error("hog mode wasn't turned on: \(uid) is no longer the output")
                return NSSound.beep()
            }
            guard outputFallback.takesHogModeFix else {
                logger.error("hog mode wasn't turned on: \(uid) plays in the chosen one's place")
                return NSSound.beep()
            }
            do {
                try settings.set(\.hogMode, to: true)
            } catch {
                return fail("Couldn't turn on hog mode", error)
            }
        }
        guard let engine else {
            return logger.error(
                "\(String(describing: fix)) is made, but there's no engine to play the track again")
        }
        // The window the fix was asked from: the main window under the dialog, or the details.
        let over = NSApp.keyWindow ?? window?.window
        Task {
            let state = await engine.state
            do throws(ReplayRefusal) {
                let position = try shown.replayPosition(in: state)
                await engine.play(at: position)
            } catch {
                logger.error(
                    "\(String(describing: fix)) is made, but the track isn't played again: \(error)"
                )
                guard let over else { return }
                let notice = error.notice(after: fix)
                let alert = NSAlert()
                alert.messageText = notice.title
                alert.informativeText = notice.text
                alert.beginSheetModal(for: over, completionHandler: nil)
            }
        }
    }
}
