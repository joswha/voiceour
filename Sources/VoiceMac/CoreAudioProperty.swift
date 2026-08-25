import CoreAudio

enum CoreAudioProperty {
    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: UInt32 = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func read<T>(
        _ address: AudioObjectPropertyAddress,
        from objectID: AudioObjectID,
        initialValue: T
    ) -> T? {
        var value = initialValue
        var size = UInt32(MemoryLayout<T>.size)
        var address = address
        guard AudioObjectHasProperty(objectID, &address) else {
            return nil
        }
        let didRead = withUnsafeMutableBytes(of: &value) { bytes in
            guard let baseAddress = bytes.baseAddress else { return false }
            return AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, baseAddress) == noErr
        }
        return didRead ? value : nil
    }

    /// Reads a `CFString`-valued property. Separate from ``read(_:from:initialValue:)``
    /// because the HAL hands back a *retained* `CFString` rather than a POD value, so the
    /// reference has to be consumed exactly once instead of copied out of raw bytes.
    static func readString(_ address: AudioObjectPropertyAddress, from objectID: AudioObjectID) -> String? {
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<CFString?>.size)
        var address = address
        guard AudioObjectHasProperty(objectID, &address),
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr,
            let string = value?.takeRetainedValue()
        else {
            return nil
        }
        return string as String
    }

    static func deviceIDs() -> [AudioObjectID]? {
        var address = address(kAudioHardwarePropertyDevices, scope: kAudioObjectPropertyScopeGlobal)
        var size: UInt32 = 0
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr, size > 0 else {
            return nil
        }

        var deviceIDs = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &deviceIDs) == noErr else {
            return nil
        }
        return deviceIDs
    }
}
