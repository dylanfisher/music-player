import DisplayText
import Foundation
import Library
import Metadata
import Settings

/// A line of the info window's File tab, which shows what the file is and doesn't edit it.
enum FileRow: CaseIterable {
    case format, sampleRate, bitDepth, channels, length, bitRate, size, tag, modified, created,
        folder

    var title: String {
        switch self {
        case .format: TrackColumn.codec.title
        case .sampleRate: TrackColumn.sampleRate.title
        case .bitDepth: SmartField.bitDepth.title
        case .channels: TrackColumn.channels.title
        case .length: "Length"
        case .bitRate: TrackColumn.bitRate.title
        case .size: TrackColumn.size.title
        case .tag: "Tag"
        case .modified: "Modified"
        case .created: "Created"
        case .folder: BrowserGrouping.folders.header
        }
    }

    /// The row's text for one track; empty when the file's facts weren't read.
    func text(_ track: EditableTrack) -> String {
        if self == .folder { return (track.path as NSString).deletingLastPathComponent }
        guard let file = track.file else { return "" }
        let audio = file.audio
        let seconds = Double(audio.lengthFrames) / Double(max(1, audio.sampleRateHz))
        switch self {
        case .format: return audio.codec.rawValue.uppercased()
        case .sampleRate: return sampleRateText(audio.sampleRateHz)
        case .bitDepth: return audio.bitsPerSample.map { DisplayText.bitDepth($0) } ?? "—"
        case .channels: return String(audio.channels)
        case .length: return clock(seconds)
        case .bitRate:
            // The whole file's average, tags and art included.
            guard seconds > 0 else { return "—" }
            return kbpsText(Double(file.sizeBytes) * 8 / seconds / 1000)
        case .size: return fileSizeText(file.sizeBytes)
        case .tag: return file.tagScheme
        case .modified: return Self.dateText(file.modified)
        case .created: return Self.dateText(file.created)
        case .folder: preconditionFailure("handled above")
        }
    }

    private static func dateText(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
    }
}
