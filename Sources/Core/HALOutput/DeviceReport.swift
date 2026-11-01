import DisplayText

/// Plain-text listing of devices and the formats they offer, for `--list-devices`.
public func deviceReport(_ devices: [AudioDevice]) -> String {
    var lines: [String] = []
    for device in devices {
        lines.append("\(device.name) — \(device.manufacturer)")
        lines.append("  uid: \(device.uid)")
        lines.append("  transport: \(device.transport)")
        lines.append("  hog mode: \(device.hogModeOwner.map { "held by pid \($0)" } ?? "free")")
        lines.append("  nominal rate: \(kilohertz(device.nominalSampleRateHz)) kHz")
        lines.append(
            "  available rates: \(device.availableSampleRatesHz.map(kilohertz).joined(separator: ", ")) kHz"
        )
        for (index, stream) in device.outputStreams.enumerated() {
            lines.append("  output stream \(index + 1), now: \(stream.current.summary)")
            for format in stream.available {
                lines.append("    \(format.summary)")
            }
        }
        lines.append("")
    }
    return lines.joined(separator: "\n")
}
