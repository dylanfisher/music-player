import Foundation

/// Where the engine sends tracks: the local DAC through the CoreAudio HAL, or (phase 9) a UPnP
/// renderer. The engine drives it a track at a time, never a sample at a time, so an output that
/// fetches and decodes files itself fits the same shape. Every method returns at once; what
/// happens as a result arrives on `events`.
public protocol Output: AnyObject, Sendable {
    /// What the output did, in order. One engine reads it.
    var events: AsyncStream<OutputEvent> { get }
    /// Whether `setVolume` does anything.
    var hasVolume: Bool { get }

    /// Drops whatever is loaded, and the next item, and loads `item` from `startSeconds` in. Plays
    /// as soon as it can when `playing` is true, otherwise waits for `play()`.
    func load(_ item: OutputItem, startSeconds: Double, playing: Bool)
    /// The item to play when the current one ends, gapless when the output can manage it. Nil
    /// clears it. Ignored when nothing is loaded.
    func setNext(_ item: OutputItem?)
    func play()
    func pause()
    /// Drops everything loaded and releases the device.
    func stop()
    func seek(toSeconds seconds: Double)
    /// Linear amplitude from 0 to 1.
    func setVolume(_ gain: Double)
    /// How far into which item playback is, or nil when nothing is loaded.
    func position() -> OutputPosition?
    /// Stops, puts the device back the way it was, and ends `events`, then returns. Call it before
    /// the process exits.
    func close()
}

/// A track as an output sees it. The engine gives each load a new `id`, so the same file queued
/// twice, or repeated, is two items.
public struct OutputItem: Sendable, Equatable {
    public typealias ID = Int

    public var id: ID
    public var url: URL
}

public struct OutputPosition: Sendable, Equatable {
    public var item: OutputItem.ID
    public var seconds: Double

    public init(item: OutputItem.ID, seconds: Double) {
        self.item = item
        self.seconds = seconds
    }
}
