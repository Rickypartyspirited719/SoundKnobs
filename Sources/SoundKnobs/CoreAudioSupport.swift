import CoreAudio
import Foundation

// MARK: - Errors

enum CoreAudioError: LocalizedError {
    case osStatus(OSStatus, String)

    var errorDescription: String? {
        switch self {
        case .osStatus(let status, let what):
            return "\(what) failed (OSStatus \(status))"
        }
    }
}

@discardableResult
func check(_ status: OSStatus, _ what: String) throws -> OSStatus {
    guard status == noErr else { throw CoreAudioError.osStatus(status, what) }
    return status
}

// MARK: - Convenience

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)
}

func propertyAddress(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

// MARK: - Property readers

/// Read a fixed-size (plain-old-data) property.
func readPOD<T>(
    _ object: AudioObjectID,
    _ selector: AudioObjectPropertySelector,
    _ template: T
) throws -> T {
    var address = propertyAddress(selector)
    var size = UInt32(MemoryLayout<T>.size)
    var value = template
    try withUnsafeMutablePointer(to: &value) { pointer in
        _ = try check(
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, UnsafeMutableRawPointer(pointer)),
            "Read property \(selector) on object \(object)"
        )
    }
    return value
}

/// Read a variable-length list of AudioObjectIDs.
func readObjectIDList(
    _ object: AudioObjectID,
    _ selector: AudioObjectPropertySelector
) throws -> [AudioObjectID] {
    var address = propertyAddress(selector)
    var dataSize: UInt32 = 0
    try check(
        AudioObjectGetPropertyDataSize(object, &address, 0, nil, &dataSize),
        "Read size of property \(selector)"
    )
    let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
    guard count > 0 else { return [] }
    var list = [AudioObjectID](repeating: .unknown, count: count)
    try check(
        AudioObjectGetPropertyData(object, &address, 0, nil, &dataSize, &list),
        "Read property \(selector)"
    )
    return list
}

/// Read a CFString property as a Swift String.
func readString(
    _ object: AudioObjectID,
    _ selector: AudioObjectPropertySelector
) throws -> String {
    var address = propertyAddress(selector)
    var size = UInt32(MemoryLayout<CFString?>.size)
    var value: CFString?
    _ = try withUnsafeMutablePointer(to: &value) { pointer in
        try check(
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer),
            "Read string property \(selector) on object \(object)"
        )
    }
    return (value as String?) ?? ""
}