import Foundation
import Playback

/// The dialog a playback problem shows at once, for one the app can fix (ADR 0111).
struct ProblemDialog: Equatable {
    enum Button: Equatable {
        case fix(PlaybackFix)
        case cancel
    }

    var shown: ShownProblem
    var title: String
    var text: String
    /// In order; the first is the default.
    var buttons: [Button]

    /// Nil for a problem with nothing to offer, which only the status bar shows.
    init?(_ shown: ShownProblem) {
        guard let fix = shown.problem.fix else { return nil }
        self.shown = shown
        title = fix.dialogTitle
        text = sentence(shown.problem.message) + " " + fix.explanation
        buttons = [.fix(fix), .cancel]
    }
}

extension ProblemDialog.Button {
    var title: String {
        switch self {
        case .fix(let fix): fix.buttonTitle
        case .cancel: "Cancel"
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
