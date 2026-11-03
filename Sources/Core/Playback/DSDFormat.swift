import DisplayText

/// The format codes `SignalFormat` gives a DSD file's 1-bit stream and the DoP frames it's
/// carried in (ADR 0064). Neither is a CoreAudio format.
public let dsdFormatID = "DSD "
public let dopFormatID = "DoP "

/// The DSD bits a DoP frame carries per channel, under its 8-bit marker, so DoP runs at a
/// sixteenth of the DSD rate.
public let dopDSDBitsPerFrame = 16
/// A DoP word's width: the marker and the 16 DSD bits.
public let dopWordBits: UInt32 = 24

/// "DoP at 352.8 kHz": how the panel and the now-playing line name what a DSD track plays as.
public func dopText(carrierRateHz: Double) -> String { "DoP at \(kilohertz(carrierRateHz)) kHz" }
