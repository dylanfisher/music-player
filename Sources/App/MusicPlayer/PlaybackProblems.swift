import NowPlaying

/// Where playback problems are explained: the details window the status bar opens (ADR 0111).
extension AppDelegate {
    /// Opens the details of `shown` with the output's last signal path and, for a device, its
    /// hog mode setting, which the config mirrors from the device in use.
    func showProblem(_ shown: ShownProblem) {
        problemWindow.show(
            ProblemReport(
                shown, path: signalPath?.path,
                hogMode: rendererOutput == nil ? settings?[\.hogMode] : nil))
    }
}
