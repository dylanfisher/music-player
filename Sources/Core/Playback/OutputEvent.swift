/// Something an output did. Each names the item it concerns, so the engine can ignore events about
/// an item it has already replaced.
public enum OutputEvent: Sendable {
    /// The item's first sample reached the device.
    case trackStarted(OutputItem.ID, TrackInfo)
    /// The item's last sample reached the device.
    case trackEnded(OutputItem.ID)
    /// The output changed the device's format for this item, before its `trackStarted`.
    case formatChanged(OutputItem.ID, FormatChange)
    /// The item couldn't be opened, or stopped partway. The output carries on with what it has.
    case trackFailed(OutputItem.ID, any Error)
    /// Nothing is left to play after this item, and the output has released the device.
    case finished(OutputItem.ID)
    /// Frames of silence played because decoding fell behind.
    case underrun(frames: Int)
    /// The device went away. The output has dropped everything; playback can resume at
    /// `positionSeconds` into the item once the device is back.
    case deviceLost(OutputItem.ID?, positionSeconds: Double)
    /// The lost device is connected again.
    case deviceReturned
    /// The device failed, so the output stopped after putting back what it could.
    case failed(OutputItem.ID?, any Error)
}

/// What an output knows about a track once it starts.
public struct TrackInfo: Sendable, Equatable {
    public var durationSeconds: Double
    /// What the output is running while it plays, for display, such as
    /// `ADI-2 DAC: 'lpcm' 2 ch 32-bit int @ 96 kHz, non-mixable, hog mode`. Nil for an output
    /// that doesn't know, such as a renderer that decodes the file itself.
    public var outputFormat: String?

    public init(durationSeconds: Double, outputFormat: String?) {
        self.durationSeconds = durationSeconds
        self.outputFormat = outputFormat
    }
}

public struct FormatChange: Sendable, Equatable {
    /// Nil when nothing was configured before.
    public var from: String?
    public var to: String
    /// From the old track's last sample leaving the output to the new track's first one, or from
    /// the load for the first track. Nil for an output that can't measure it.
    public var switchSeconds: Double?

    public init(from: String?, to: String, switchSeconds: Double?) {
        self.from = from
        self.to = to
        self.switchSeconds = switchSeconds
    }
}
