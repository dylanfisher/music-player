import Foundation

/// DSF's block size per channel.
let dsfBlockBytes = 4096

/// `samples` bits of a quiet sine, oldest bit highest in each byte, from a first-order
/// sigma-delta modulator: enough like real DSD that every byte value turns up.
func dsdTone(samples: Int, rateHz: Int, channel: Int) -> Data {
    var bytes = Data(count: (samples + 7) / 8)
    var integrator = 0.0
    let hertz = 440.0 + 220.0 * Double(channel)
    for index in 0..<samples {
        let input = 0.25 * sin(2 * .pi * hertz * Double(index) / Double(rateHz))
        let bit = integrator >= 0
        integrator += input - (bit ? 1 : -1)
        if bit { bytes[index / 8] |= 0x80 >> UInt8(index % 8) }
    }
    return bytes
}

/// `byte` with its bits in the opposite order, as DSF stores DSD.
func bitReversed(_ byte: UInt8) -> UInt8 {
    var reversed: UInt8 = 0
    for bit in 0..<8 where byte & (1 << bit) != 0 { reversed |= 0x80 >> bit }
    return reversed
}

/// A DSF file of `channels`, each given oldest bit highest and stored reversed, as DSF stores it,
/// in blocks with the last zero-filled. `samplesPerChannel` is every bit unless given; `tag`, an
/// ID3v2 tag, goes at the end where the metadata pointer says.
func dsfFile(rateHz: Int, channels: [Data], samplesPerChannel: Int? = nil, tag: Data? = nil)
    -> Data
{
    let bytesPerChannel = channels.map(\.count).max() ?? 0
    let blocks = (bytesPerChannel + dsfBlockBytes - 1) / dsfBlockBytes
    var audio = Data(capacity: blocks * dsfBlockBytes * channels.count)
    for block in 0..<blocks {
        for channel in channels {
            let start = block * dsfBlockBytes
            let end = min(channel.count, start + dsfBlockBytes)
            let present =
                start < end
                ? channel[channel.startIndex + start..<channel.startIndex + end] : Data()
            audio.append(contentsOf: present.map(bitReversed))
            audio.append(Data(count: dsfBlockBytes - present.count))
        }
    }
    let dataStart = 28 + 52 + 12
    let total = dataStart + audio.count + (tag?.count ?? 0)
    var file = Data()
    file.append(ascii: "DSD ")
    file.appendLittleEndian(UInt64(28))
    file.appendLittleEndian(UInt64(total))
    file.appendLittleEndian(UInt64(tag == nil ? 0 : dataStart + audio.count))
    file.append(ascii: "fmt ")
    file.appendLittleEndian(UInt64(52))
    file.appendLittleEndian(UInt32(1))  // format version
    file.appendLittleEndian(UInt32(0))  // DSD raw
    file.appendLittleEndian(UInt32(channels.count == 1 ? 1 : 2))  // mono or stereo
    file.appendLittleEndian(UInt32(channels.count))
    file.appendLittleEndian(UInt32(rateHz))
    file.appendLittleEndian(UInt32(1))  // oldest bit lowest
    file.appendLittleEndian(UInt64(samplesPerChannel ?? bytesPerChannel * 8))
    file.appendLittleEndian(UInt32(dsfBlockBytes))
    file.appendLittleEndian(UInt32(0))
    file.append(ascii: "data")
    file.appendLittleEndian(UInt64(12 + audio.count))
    file.append(audio)
    if let tag { file.append(tag) }
    return file
}

/// A DSDIFF chunk: its ID, a 64-bit big-endian size, the body and a pad byte to an even length.
func dffChunk(_ id: String, _ body: Data) -> Data {
    var chunk = Data()
    chunk.append(ascii: id)
    chunk.appendBigEndian(UInt64(body.count))
    chunk.append(body)
    if body.count % 2 == 1 { chunk.append(0) }
    return chunk
}

/// A DSDIFF file of `channels`, oldest bit highest, one byte of each in turn. `compression` is
/// the `CMPR` type; `tag`, an ID3v2 tag, goes in an `ID3 ` chunk after the audio.
func dffFile(rateHz: Int, channels: [Data], compression: String = "DSD ", tag: Data? = nil)
    -> Data
{
    var properties = Data()
    properties.append(ascii: "SND ")
    var rate = Data()
    rate.appendBigEndian(UInt32(rateHz))
    properties.append(dffChunk("FS  ", rate))
    var layout = Data()
    layout.appendBigEndian(UInt16(channels.count))
    for id in ["SLFT", "SRGT", "C   ", "LFE ", "LS  ", "RS  "].prefix(channels.count) {
        layout.append(ascii: id)
    }
    properties.append(dffChunk("CHNL", layout))
    var name = Data()
    name.append(ascii: compression)
    name.append(0)  // an empty name
    properties.append(dffChunk("CMPR", name))
    var audio = Data()
    let bytesPerChannel = channels.map(\.count).min() ?? 0
    for index in 0..<bytesPerChannel {
        for channel in channels { audio.append(channel[channel.startIndex + index]) }
    }
    var version = Data()
    version.appendBigEndian(UInt32(0x0105_0000))
    var body = Data()
    body.append(ascii: "DSD ")
    body.append(dffChunk("FVER", version))
    body.append(dffChunk("PROP", properties))
    body.append(dffChunk(compression, audio))
    if let tag { body.append(dffChunk("ID3 ", tag)) }
    var file = Data()
    file.append(ascii: "FRM8")
    file.appendBigEndian(UInt64(body.count))
    file.append(body)
    return file
}
