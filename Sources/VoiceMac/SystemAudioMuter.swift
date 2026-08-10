import CoreAudio
import Foundation
import VoiceCore

public actor SystemAudioMuter: SystemAudioMuting {
    private enum OwnedProperty {
        case mute(priorValue: UInt32)
        case volume(priorValue: Float32)
    }

    private struct Ownership {
        var deviceID: AudioObjectID
        var property: OwnedProperty

        init(deviceID: AudioObjectID, property: OwnedProperty) {
            self.deviceID = deviceID
            self.property = property
        }

        init?(durableOwnership: DurableOwnership) {
            deviceID = AudioObjectID(durableOwnership.deviceID)
            switch durableOwnership.property {
            case "mute":
                guard let priorValue = durableOwnership.priorUInt32 else { return nil }
                property = .mute(priorValue: priorValue)
            case "volume":
                guard let priorValue = durableOwnership.priorFloat32 else { return nil }
                property = .volume(priorValue: priorValue)
            default:
                return nil
            }
        }
    }

    private struct DurableOwnership: Codable {
        var deviceID: UInt32
        var property: String
        var priorUInt32: UInt32?
        var priorFloat32: Float32?

        init(_ ownership: Ownership) {
            deviceID = UInt32(ownership.deviceID)
            switch ownership.property {
            case .mute(let priorValue):
                property = "mute"
                priorUInt32 = priorValue
                priorFloat32 = nil
            case .volume(let priorValue):
                property = "volume"
                priorUInt32 = nil
                priorFloat32 = priorValue
            }
        }
    }

    private var ownership: Ownership?

    public init() {
        Self.recoverDurableOwnershipIfNeeded()
    }

    public func mute(scope: MuteScope) async -> Bool {
        if ownership != nil {
            await restore()
        }

        guard let deviceID = Self.defaultOutputDevice(), deviceID != AudioObjectID(kAudioObjectUnknown) else {
            return false
        }
        guard Self.shouldMute(deviceID: deviceID, scope: scope) else {
            return false
        }

        if let priorMuteValue = Self.readUInt32(
            deviceID: deviceID, selector: kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        {
            let newOwnership = Ownership(deviceID: deviceID, property: .mute(priorValue: priorMuteValue))
            guard Self.writeDurableOwnershipFlag(newOwnership) else {
                return false
            }
            if Self.writeUInt32(
                deviceID: deviceID, selector: kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput, value: 1
            ) {
                ownership = newOwnership
                return true
            }
            Self.removeDurableOwnershipFlag()
        }

        if let priorVolumeValue = Self.readFloat32(
            deviceID: deviceID, selector: kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput)
        {
            let newOwnership = Ownership(deviceID: deviceID, property: .volume(priorValue: priorVolumeValue))
            guard Self.writeDurableOwnershipFlag(newOwnership) else {
                return false
            }
            if Self.writeFloat32(
                deviceID: deviceID, selector: kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput,
                value: 0)
            {
                ownership = newOwnership
                return true
            }
            Self.removeDurableOwnershipFlag()
        }

        return false
    }

    public func restore() async {
        guard let ownership else {
            Self.removeDurableOwnershipFlag()
            return
        }

        _ = Self.restore(ownership: ownership)
        self.ownership = nil
        Self.removeDurableOwnershipFlag()
    }

    private static func restore(ownership: Ownership) -> Bool {
        switch ownership.property {
        case .mute(let priorValue):
            guard
                readUInt32(
                    deviceID: ownership.deviceID,
                    selector: kAudioDevicePropertyMute,
                    scope: kAudioDevicePropertyScopeOutput
                ) == 1
            else {
                return false
            }
            return writeUInt32(
                deviceID: ownership.deviceID,
                selector: kAudioDevicePropertyMute,
                scope: kAudioDevicePropertyScopeOutput,
                value: priorValue
            )
        case .volume(let priorValue):
            guard
                let currentValue = readFloat32(
                    deviceID: ownership.deviceID,
                    selector: kAudioDevicePropertyVolumeScalar,
                    scope: kAudioDevicePropertyScopeOutput
                ),
                abs(currentValue) <= Float32.ulpOfOne
            else {
                return false
            }
            return writeFloat32(
                deviceID: ownership.deviceID,
                selector: kAudioDevicePropertyVolumeScalar,
                scope: kAudioDevicePropertyScopeOutput,
                value: priorValue
            )
        }
    }

    private static func defaultOutputDevice() -> AudioObjectID? {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        return status == noErr ? deviceID : nil
    }

    private static func shouldMute(deviceID: AudioObjectID, scope: MuteScope) -> Bool {
        switch scope {
        case .allOutputs:
            return true
        case .builtInOutputOnly:
            guard
                let transport = readUInt32(
                    deviceID: deviceID,
                    selector: kAudioDevicePropertyTransportType,
                    scope: kAudioObjectPropertyScopeGlobal
                )
            else {
                return false
            }
            return transport == kAudioDeviceTransportTypeBuiltIn
        }
    }

    private static func readUInt32(
        deviceID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> UInt32? {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = propertyAddress(selector: selector, scope: scope)
        guard AudioObjectHasProperty(deviceID, &address) else {
            return nil
        }

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private static func writeUInt32(
        deviceID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        value: UInt32
    ) -> Bool {
        var newValue = value
        var address = propertyAddress(selector: selector, scope: scope)
        guard AudioObjectHasProperty(deviceID, &address) else {
            return false
        }

        let status = AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &newValue
        )
        return status == noErr
    }

    private static func readFloat32(
        deviceID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> Float32? {
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = propertyAddress(selector: selector, scope: scope)
        guard AudioObjectHasProperty(deviceID, &address) else {
            return nil
        }

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private static func writeFloat32(
        deviceID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        value: Float32
    ) -> Bool {
        var newValue = value
        var address = propertyAddress(selector: selector, scope: scope)
        guard AudioObjectHasProperty(deviceID, &address) else {
            return false
        }

        let status = AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<Float32>.size),
            &newValue
        )
        return status == noErr
    }

    private static func propertyAddress(
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func writeDurableOwnershipFlag(_ ownership: Ownership) -> Bool {
        guard let flagURL = durableOwnershipFlagURL else {
            return false
        }

        do {
            try FileManager.default.createDirectory(
                at: flagURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(DurableOwnership(ownership))
            try data.write(to: flagURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func removeDurableOwnershipFlag() {
        guard let flagURL = durableOwnershipFlagURL else {
            return
        }
        try? FileManager.default.removeItem(at: flagURL)
    }

    public static func recoverDurableOwnershipIfNeeded() {
        guard let flagURL = durableOwnershipFlagURL else {
            return
        }
        guard let data = try? Data(contentsOf: flagURL) else {
            return
        }
        guard let durableOwnership = try? JSONDecoder().decode(DurableOwnership.self, from: data),
            let ownership = Ownership(durableOwnership: durableOwnership)
        else {
            removeDurableOwnershipFlag()
            return
        }

        _ = restore(ownership: ownership)
        removeDurableOwnershipFlag()
    }

    private static var durableOwnershipFlagURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("VoiceOour", isDirectory: true)
            .appendingPathComponent("mute-owned.flag", isDirectory: false)
    }
}
