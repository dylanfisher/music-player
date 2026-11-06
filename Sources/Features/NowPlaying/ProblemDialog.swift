import DisplayText
import Foundation
import Playback

/// The dialog a playback problem shows at once, for one the app can fix or tracks failing in a
/// row until playback stopped (ADR 0111).
struct ProblemDialog: Equatable {
    enum Button: Equatable {
        case fix(PlaybackFix)
        /// Opens the Playback Problem window.
        case details
        case cancel
        case ok
    }

    var shown: ShownProblem
    var title: String
    var text: String
    /// In order; the first is the default.
    var buttons: [Button]

    /// Nil for a problem with nothing to offer, which only the status bar shows.
    init?(_ shown: ShownProblem) {
        let problem = shown.problem
        self.shown = shown
        let failed = PlaybackProblem.failedInARow(problem.causes.map(\.tracks.count).reduce(0, +))
        switch (problem.causes.count, problem.fix) {
        case (0, nil): return nil
        case (0, let fix?):
            title = fix.dialogTitle
            text = sentence(problem.message) + " " + fix.explanation
            buttons = [.fix(fix), .cancel]
        case (1, let fix):
            title = failed
            text = sentence(problem.causes[0].message) + (fix.map { " " + $0.explanation } ?? "")
            buttons = fix.map { [.fix($0), .cancel] } ?? [.ok]
        default:
            title = failed
            text = problem.causes.map { "\(tracks($0.tracks.count)): " + sentence($0.message) }
                .joined(separator: "\n")
            buttons = problem.fix.map { [.fix($0), .details, .cancel] } ?? [.details, .ok]
        }
    }
}

extension ProblemDialog.Button {
    var title: String {
        switch self {
        case .fix(let fix): fix.buttonTitle
        case .details: "Show Details"
        case .cancel: "Cancel"
        case .ok: "OK"
        }
    }
}

extension PlaybackFix {
    var buttonTitle: String {
        switch self {
        case .turnOnHogMode: "Turn On Hog Mode"
        }
    }

    var dialogTitle: String {
        switch self {
        case .turnOnHogMode: "DSD needs exclusive access to the device"
        }
    }

    /// The title of what's said once the fix is made.
    var madeTitle: String {
        switch self {
        case .turnOnHogMode: "Hog mode is on for this device"
        }
    }

    /// What the button does, after the problem's message.
    var explanation: String {
        switch self {
        case .turnOnHogMode:
            "Turn on hog mode for this device to play it. While the app plays, other apps can't"
                + " play through the device."
        }
    }
}

/// "The file is damaged." from "the file is damaged".
func sentence(_ clause: String) -> String {
    clause.prefix(1).uppercased() + clause.dropFirst() + "."
}
