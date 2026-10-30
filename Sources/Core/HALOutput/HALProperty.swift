import CoreAudio

/// A failed HAL call, with the property it was reading.
public struct HALError: Error, CustomStringConvertible {
    public var selector: AudioObjectPropertySelector
    public var status: OSStatus

    public var description: String {
        "HAL property '\(fourCharCode(selector))' failed: '\(fourCharCode(UInt32(bitPattern: status)))' (\(status))"
    }
}

/// A failed CoreAudio call that isn't a property read or write.
public struct OSStatusError: Error, CustomStringConvertible {
    public var operation: String
    public var status: OSStatus

    public var description: String {
        "\(operation) failed: '\(fourCharCode(UInt32(bitPattern: status)))' (\(status))"
    }
}

public func throwIfError(_ operation: String, _ status: OSStatus) throws {
    guard status == noErr else { throw OSStatusError(operation: operation, status: status) }
}

/// Renders a CoreAudio four-character code such as `'lpcm'`. Codes with non-printable bytes,
/// which most plain OSStatus values have, come back as hex.
public func fourCharCode(_ code: UInt32) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }
    guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else {
        return "0x" + String(code, radix: 16)
    }
    return String(decoding: bytes, as: UTF8.self)
}

func address(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

/// Reads a fixed-size property. `T` must be a trivial type: a number, a C struct, or `Unmanaged`.
func readScalar<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> T {
    var address = address
    var size = UInt32(MemoryLayout<T>.size)
    let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
    defer { value.deallocate() }
    let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, value)
    guard status == noErr else { throw HALError(selector: address.mSelector, status: status) }
    return value.pointee
}

/// Reads a variable-length property holding an array of `T`.
func readArray<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> [T] {
    var address = address
    var size: UInt32 = 0
    var status = AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size)
    guard status == noErr else { throw HALError(selector: address.mSelector, status: status) }
    let count = Int(size) / MemoryLayout<T>.stride
    return try [T](unsafeUninitializedCapacity: count) { buffer, initialized in
        status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, buffer.baseAddress!)
        guard status == noErr else { throw HALError(selector: address.mSelector, status: status) }
        initialized = Int(size) / MemoryLayout<T>.stride
    }
}

func writeScalar<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: T)
    throws
{
    var address = address
    let status = withUnsafeBytes(of: value) { bytes in
        AudioObjectSetPropertyData(
            object, &address, 0, nil, UInt32(bytes.count), bytes.baseAddress!)
    }
    guard status == noErr else { throw HALError(selector: address.mSelector, status: status) }
}

func readString(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> String {
    // The HAL returns these CFStrings retained; the caller owns them.
    let value: Unmanaged<CFString> = try readScalar(object, address)
    return value.takeRetainedValue() as String
}
