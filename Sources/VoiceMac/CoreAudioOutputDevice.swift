import CoreAudio
import Foundation

/// Thin, typed access to the output-device properties `SystemAudioMuter` needs.
///
/// Everything here is public CoreAudio HAL. The point of the namespace is that
/// every call site reads as an intent ("settable volume controls", "set mute")
/// rather than as four positional CoreAudio arguments, and that the raw
/// `AudioObjectGetPropertyData` shapes exist exactly once.
enum CoreAudioOutputDevice {
    /// A single settable output volume control and the value it holds now.
    struct VolumeControl: Equatable {
        var element: UInt32
        var value: Float32
    }

    static func defaultDevice() -> AudioObjectID? {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != AudioObjectID(kAudioObjectUnknown) else {
            return nil
        }
        return deviceID
    }

    /// The device's main volume when it has a settable one, otherwise every
    /// settable output channel.
    ///
    /// The second branch is not a fallback for exotic hardware: AirPods Max
    /// publish no main-element volume at all and move only on channels 1 and 2,
    /// while MacBook Pro Speakers publish the main element and nothing else.
    static func settableVolumeControls(deviceID: AudioObjectID) -> [VolumeControl] {
        if let main = settableVolume(deviceID: deviceID, element: kAudioObjectPropertyElementMain) {
            return [VolumeControl(element: kAudioObjectPropertyElementMain, value: main)]
        }

        let channelCount = outputChannelCount(deviceID: deviceID)
        guard channelCount > 0 else {
            return []
        }
        return (1...UInt32(channelCount)).compactMap { element in
            settableVolume(deviceID: deviceID, element: element)
                .map { VolumeControl(element: element, value: $0) }
        }
    }

    /// The current mute value, but only when the device will let us write it.
    static func settableMute(deviceID: AudioObjectID) -> UInt32? {
        var muteAddress = address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        guard isSettable(deviceID: deviceID, address: &muteAddress) else {
            return nil
        }
        return mute(deviceID: deviceID, element: kAudioObjectPropertyElementMain)
    }

    static func mute(deviceID: AudioObjectID, element: UInt32) -> UInt32? {
        readUInt32(
            deviceID: deviceID,
            address: address(
                kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput, element: element))
    }

    @discardableResult
    static func setMute(deviceID: AudioObjectID, element: UInt32, value: UInt32) -> Bool {
        writeUInt32(
            deviceID: deviceID,
            address: address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput, element: element),
            value: value
        )
    }

    static func volume(deviceID: AudioObjectID, element: UInt32) -> Float32? {
        readFloat32(
            deviceID: deviceID,
            address: address(
                kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: element))
    }

    @discardableResult
    static func setVolume(deviceID: AudioObjectID, element: UInt32, value: Float32) -> Bool {
        writeFloat32(
            deviceID: deviceID,
            address: address(
                kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: element),
            value: value
        )
    }

    static func uid(deviceID: AudioObjectID) -> String? {
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<CFString?>.size)
        var uidAddress = address(kAudioDevicePropertyDeviceUID, scope: kAudioObjectPropertyScopeGlobal)
        guard AudioObjectHasProperty(deviceID, &uidAddress),
            AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &size, &value) == noErr,
            let uid = value?.takeRetainedValue()
        else {
            return nil
        }
        return uid as String
    }

    static func device(forUID uid: String) -> AudioObjectID? {
        var devicesAddress = address(kAudioHardwarePropertyDevices, scope: kAudioObjectPropertyScopeGlobal)
        var size: UInt32 = 0
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(systemObject, &devicesAddress, 0, nil, &size) == noErr, size > 0 else {
            return nil
        }

        var deviceIDs = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(systemObject, &devicesAddress, 0, nil, &size, &deviceIDs) == noErr else {
            return nil
        }
        return deviceIDs.first { self.uid(deviceID: $0) == uid }
    }

    private static func settableVolume(deviceID: AudioObjectID, element: UInt32) -> Float32? {
        var volumeAddress = address(
            kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: element)
        guard isSettable(deviceID: deviceID, address: &volumeAddress) else {
            return nil
        }
        return readFloat32(deviceID: deviceID, address: volumeAddress)
    }

    private static func outputChannelCount(deviceID: AudioObjectID) -> Int {
        var configAddress = address(
            kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &configAddress, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }

        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &configAddress, 0, nil, &size, buffer) == noErr else {
            return 0
        }

        let bufferList = UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self))
        return bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func isSettable(deviceID: AudioObjectID, address: inout AudioObjectPropertyAddress) -> Bool {
        guard AudioObjectHasProperty(deviceID, &address) else {
            return false
        }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr else {
            return false
        }
        return settable.boolValue
    }

    private static func readUInt32(deviceID: AudioObjectID, address: AudioObjectPropertyAddress) -> UInt32? {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = address
        guard AudioObjectHasProperty(deviceID, &address) else {
            return nil
        }
        return AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func writeUInt32(
        deviceID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        value: UInt32
    ) -> Bool {
        var newValue = value
        var address = address
        guard AudioObjectHasProperty(deviceID, &address) else {
            return false
        }
        let status = AudioObjectSetPropertyData(
            deviceID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &newValue)
        return status == noErr
    }

    private static func readFloat32(deviceID: AudioObjectID, address: AudioObjectPropertyAddress) -> Float32? {
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = address
        guard AudioObjectHasProperty(deviceID, &address) else {
            return nil
        }
        return AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func writeFloat32(
        deviceID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        value: Float32
    ) -> Bool {
        var newValue = value
        var address = address
        guard AudioObjectHasProperty(deviceID, &address) else {
            return false
        }
        let status = AudioObjectSetPropertyData(
            deviceID, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &newValue)
        return status == noErr
    }

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: UInt32 = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }
}
