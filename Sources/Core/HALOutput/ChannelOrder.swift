import AudioToolbox

/// What a channel carries, as far as a downmix tells channels apart.
enum ChannelRole: Sendable, Equatable {
    case left, right, centre, lfe, leftSurround, rightSurround, backCentre
}

/// The channels a decoder hands on, in order (ADR 0071).
struct ChannelOrder: Sendable, Equatable {
    let roles: [ChannelRole]
    /// The file doesn't name its channels, or names one a downmix has no role for, so they're
    /// taken to be in the WAV and FLAC default order.
    let isAssumed: Bool

    /// The WAV and FLAC default order for `count` channels: L R C LFE, then the surrounds.
    /// Channels past the eighth are left out of a downmix.
    init(defaultFor count: Int, isAssumed: Bool) {
        let roles: [ChannelRole] =
            switch count {
            case 1: [.centre]
            case 2: [.left, .right]
            case 3: [.left, .right, .centre]
            case 4: [.left, .right, .leftSurround, .rightSurround]
            case 5: [.left, .right, .centre, .leftSurround, .rightSurround]
            case 6: [.left, .right, .centre, .lfe, .leftSurround, .rightSurround]
            case 7: [.left, .right, .centre, .lfe, .backCentre, .leftSurround, .rightSurround]
            default:
                [
                    .left, .right, .centre, .lfe, .leftSurround, .rightSurround, .leftSurround,
                    .rightSurround,
                ] + Array(repeating: .lfe, count: max(0, count - 8))
            }
        self.roles = roles
        self.isAssumed = isAssumed
    }

    init(roles: [ChannelRole]) {
        self.roles = roles
        isAssumed = false
    }
}

/// The role of the channel a CoreAudio label names, or nil for one a downmix has no role for.
/// A centre-left or centre-right channel goes to its side whole.
private func role(of label: AudioChannelLabel) -> ChannelRole? {
    switch label {
    case kAudioChannelLabel_Left, kAudioChannelLabel_LeftCenter: .left
    case kAudioChannelLabel_Right, kAudioChannelLabel_RightCenter: .right
    case kAudioChannelLabel_Center, kAudioChannelLabel_Mono: .centre
    case kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LFE2: .lfe
    case kAudioChannelLabel_LeftSurround, kAudioChannelLabel_LeftSurroundDirect,
        kAudioChannelLabel_RearSurroundLeft:
        .leftSurround
    case kAudioChannelLabel_RightSurround, kAudioChannelLabel_RightSurroundDirect,
        kAudioChannelLabel_RearSurroundRight:
        .rightSurround
    case kAudioChannelLabel_CenterSurround: .backCentre
    default: nil
    }
}

/// How a file of more than two channels is to be read: the labels to ask ExtAudioFile for, in
/// the order the decoder hands them on, or nil to read them as stored.
struct ChannelReading {
    let order: ChannelOrder
    let clientLabels: [AudioChannelLabel]?

    /// From the layout `file` states. Labels 1 to 11 are numbered in the WAV channel mask's order,
    /// so sorting by label puts a named layout in WAV order: ALAC's and AAC's C L R Ls Rs LFE
    /// becomes L R C LFE Ls Rs. A file that names no layout, or a channel no role fits, is read as
    /// stored in the WAV and FLAC default order, which is what those formats specify.
    init(_ file: ExtAudioFileRef, channels: Int) throws {
        guard channels > 2 else {
            self.init(order: ChannelOrder(defaultFor: channels, isAssumed: false), labels: nil)
            return
        }
        let labels = try fileLabels(file)
        guard let labels, labels.count == channels, labels.allSatisfy({ role(of: $0) != nil })
        else {
            self.init(order: ChannelOrder(defaultFor: channels, isAssumed: true), labels: nil)
            return
        }
        let sorted = labels.sorted()
        self.init(
            order: ChannelOrder(roles: sorted.map { role(of: $0)! }),
            labels: sorted == labels ? nil : sorted)
    }

    private init(order: ChannelOrder, labels: [AudioChannelLabel]?) {
        self.order = order
        clientLabels = labels
    }

    /// Asks `file` to hand the channels on in this order. Setting the client data format clears
    /// the client layout, so it's set again after each.
    func apply(to file: ExtAudioFileRef) throws {
        guard let clientLabels else { return }
        try withLayout(clientLabels) { layout, size in
            try throwIfError(
                "ExtAudioFileSetProperty(ClientChannelLayout)",
                ExtAudioFileSetProperty(
                    file, kExtAudioFileProperty_ClientChannelLayout, size, layout))
        }
    }
}

/// The labels of the layout `file` states, one per channel, or nil when it states none: a tag,
/// a bitmap or a list of descriptions, each expanded to its labels.
private func fileLabels(_ file: ExtAudioFileRef) throws -> [AudioChannelLabel]? {
    var size: UInt32 = 0
    try throwIfError(
        "ExtAudioFileGetPropertyInfo(FileChannelLayout)",
        ExtAudioFileGetPropertyInfo(file, kExtAudioFileProperty_FileChannelLayout, &size, nil))
    guard size >= layoutHeaderSize else { return nil }
    let stated = UnsafeMutableRawPointer.allocate(
        byteCount: Int(size), alignment: MemoryLayout<AudioChannelLayout>.alignment)
    defer { stated.deallocate() }
    try throwIfError(
        "ExtAudioFileGetProperty(FileChannelLayout)",
        ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileChannelLayout, &size, stated))
    let layout = stated.assumingMemoryBound(to: AudioChannelLayout.self)
    switch layout.pointee.mChannelLayoutTag {
    case kAudioChannelLayoutTag_UseChannelDescriptions: return labels(of: layout)
    case kAudioChannelLayoutTag_UseChannelBitmap:
        return try expanded(
            kAudioFormatProperty_ChannelLayoutForBitmap, layout.pointee.mChannelBitmap.rawValue)
    default:
        return try expanded(
            kAudioFormatProperty_ChannelLayoutForTag, layout.pointee.mChannelLayoutTag)
    }
}

/// The labels AudioToolbox expands a layout tag or bitmap into, or nil when it doesn't know it,
/// as for the tags that number channels without naming them.
private func expanded(_ property: AudioFormatPropertyID, _ specifier: UInt32) throws
    -> [AudioChannelLabel]?
{
    var specifier = specifier
    let specifierSize = UInt32(MemoryLayout.size(ofValue: specifier))
    var size: UInt32 = 0
    guard
        AudioFormatGetPropertyInfo(property, specifierSize, &specifier, &size) == noErr,
        size >= layoutHeaderSize
    else { return nil }
    let layout = UnsafeMutableRawPointer.allocate(
        byteCount: Int(size), alignment: MemoryLayout<AudioChannelLayout>.alignment)
    defer { layout.deallocate() }
    try throwIfError(
        "AudioFormatGetProperty(ChannelLayout)",
        AudioFormatGetProperty(property, specifierSize, &specifier, &size, layout))
    return labels(of: layout.assumingMemoryBound(to: AudioChannelLayout.self))
}

private func labels(of layout: UnsafePointer<AudioChannelLayout>) -> [AudioChannelLabel]? {
    let count = Int(layout.pointee.mNumberChannelDescriptions)
    guard count > 0 else { return nil }
    let descriptions = UnsafeRawPointer(layout).advanced(by: Int(layoutHeaderSize))
        .assumingMemoryBound(to: AudioChannelDescription.self)
    return (0..<count).map { descriptions[$0].mChannelLabel }
}

/// The bytes of a layout before its channel descriptions, all a layout named by a tag or bitmap
/// takes.
private let layoutHeaderSize = UInt32(
    MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!)

/// Runs `body` with a layout that lists `labels` as its channel descriptions.
private func withLayout(
    _ labels: [AudioChannelLabel],
    _ body: (UnsafeRawPointer, UInt32) throws -> Void
) throws {
    let size = Int(layoutHeaderSize) + labels.count * MemoryLayout<AudioChannelDescription>.stride
    let layout = UnsafeMutableRawPointer.allocate(
        byteCount: max(size, MemoryLayout<AudioChannelLayout>.size),
        alignment: MemoryLayout<AudioChannelLayout>.alignment)
    defer { layout.deallocate() }
    layout.initializeMemory(
        as: UInt8.self, repeating: 0, count: max(size, MemoryLayout<AudioChannelLayout>.size))
    let header = layout.assumingMemoryBound(to: AudioChannelLayout.self)
    header.pointee.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions
    header.pointee.mNumberChannelDescriptions = UInt32(labels.count)
    let descriptions = (layout + Int(layoutHeaderSize)).assumingMemoryBound(
        to: AudioChannelDescription.self)
    for (index, label) in labels.enumerated() { descriptions[index].mChannelLabel = label }
    try body(layout, UInt32(size))
}
