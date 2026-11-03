import Foundation
import Metadata
import Playback
import UPnP

/// A track as a renderer is offered it: the file's own bytes, under the first type of its
/// container the renderer lists (ADR 0041). Read by the Metadata parsers, without decoding.
struct RendererTrack: Sendable {
    let path: String
    /// What the server sends as `Content-Type`, such as `audio/flac`.
    let contentType: String
    let metadata: DIDLTrack
    let durationSeconds: Double
    let signal: SignalFormat

    /// The types each container is sent as, most standard first. `audio/m4a`, the one MP4 type
    /// the HEOS Denon lists, is offered for AAC only: the Denon took ALAC under it and couldn't
    /// decode it (ADR 0041), so ALAC goes only where a renderer lists a general MP4 type.
    static func types(_ format: FileFormat, _ codec: TrackAudio.Codec) -> [String] {
        switch format {
        case .flac: ["audio/flac", "audio/x-flac"]
        case .mp4:
            codec == .aac
                ? ["audio/mp4", "audio/x-m4a", "audio/m4a"] : ["audio/mp4", "audio/x-m4a"]
        case .mp3: ["audio/mpeg", "audio/mp3"]
        case .wav: ["audio/wav", "audio/x-wav", "audio/wave"]
        case .aiff: ["audio/aiff", "audio/x-aiff"]
        // The Denon lists all six, and a renderer may list only the general DSD type.
        case .dsf: ["audio/dsf", "audio/x-dsf", "audio/dsd", "audio/x-dsd"]
        case .dff: ["audio/dff", "audio/x-dff", "audio/dsd", "audio/x-dsd"]
        }
    }

    /// Throws when the file can't be read or the renderer takes none of its container's types.
    static func read(_ url: URL, for renderer: Renderer) throws(RendererOutputError)
        -> RendererTrack
    {
        let parsed: ParsedFile
        let format: FileFormat
        let size: Int
        do throws(ParseFailure) {
            let reader = ByteReader(try FileSource(path: url.path))
            format = try FileFormat(reader)
            parsed = try parse(reader)
            size = reader.size
        } catch {
            throw .unreadable(error.error(path: url.path))
        }
        let audio = parsed.metadata.audio
        guard let entry = renderer.sinkEntry(for: types(format, audio.codec)) else {
            throw .unsupported(
                format: name(format, audio.codec), renderer: renderer.name,
                accepts: renderer.httpAudioTypes)
        }
        let tags = parsed.metadata.tags
        let seconds = Double(audio.lengthFrames) / Double(max(audio.sampleRateHz, 1))
        return RendererTrack(
            path: url.path, contentType: entry.mimeType,
            metadata: DIDLTrack(
                title: tags.title ?? url.deletingPathExtension().lastPathComponent,
                artist: tags.artist ?? tags.albumArtist, album: tags.album,
                protocolInfo: entry.description, durationSeconds: seconds, sizeBytes: size,
                sampleRateHz: audio.sampleRateHz, bitsPerSample: audio.bitsPerSample,
                channels: audio.channels),
            durationSeconds: seconds,
            signal: SignalFormat(
                formatID: formatID(audio.codec), sampleRateHz: Double(audio.sampleRateHz),
                bitsPerChannel: audio.bitsPerSample.map(UInt32.init),
                channels: UInt32(audio.channels), isFloat: false))
    }

    /// For example `AIFF (PCM)` or `MP4 (ALAC)`, for saying what a renderer doesn't take.
    private static func name(_ format: FileFormat, _ codec: TrackAudio.Codec) -> String {
        "\(format.rawValue.uppercased()) (\(codec.rawValue.uppercased()))"
    }

    /// The four-character code the signal path panel names a codec by, as CoreAudio does.
    private static func formatID(_ codec: TrackAudio.Codec) -> String {
        switch codec {
        case .flac, .alac: codec.rawValue
        case .aac: "aac "
        case .mp3: ".mp3"
        case .pcm: linearPCMFormatID
        case .dsd: dsdFormatID
        }
    }
}
