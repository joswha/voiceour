import CoreAudio
import Foundation

/// Thin, typed access to the input-device properties capture needs, plus the one
/// policy decision about *which* microphone a dictation should record from.
///
/// The shape mirrors ``CoreAudioOutputDevice``: raw `AudioObjectGetPropertyData`
/// lives here exactly once and every call site reads as an intent.
public enum CoreAudioInputDevice {
    /// A device that can actually record, identified by the UID rather than the
    /// `AudioObjectID`. CoreAudio recycles device IDs across reboots and
    /// re-plugs, so the UID is the only durable handle — and it is also what
    /// `AVCaptureDevice.uniqueID` reports for the same hardware, which is how a
    /// HAL-level decision reaches an AVFoundation capture session.
    struct Device: Equatable {
        var id: AudioObjectID
        var uid: String
        var name: String
        var transportType: UInt32

        var isBluetooth: Bool {
            transportType == kAudioDeviceTransportTypeBluetooth
                || transportType == kAudioDeviceTransportTypeBluetoothLE
        }

        var isBuiltIn: Bool {
            transportType == kAudioDeviceTransportTypeBuiltIn
        }
    }

    /// Every device publishing at least one input channel.
    static func all() -> [Device] {
        CoreAudioProperty.deviceIDs()?.compactMap(describe) ?? []
    }

    static func systemDefault() -> Device? {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var defaultAddress = CoreAudioProperty.address(
            kAudioHardwarePropertyDefaultInputDevice, scope: kAudioObjectPropertyScopeGlobal)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultAddress,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != AudioObjectID(kAudioObjectUnknown) else {
            return nil
        }
        return describe(deviceID)
    }

    /// The microphone a capture should pin itself to, or `nil` to record from
    /// whatever the system default input is.
    ///
    /// It answers exactly one question: is the default input a Bluetooth
    /// headset that a working built-in microphone should replace? Because a
    /// Bluetooth headset mic is not merely slower to open, it is *absent* for
    /// over a second. Measured on AirPods Max, capturing through the identical
    /// `AVCaptureSession` code path:
    ///
    /// | pinned device          | first buffer | first non-zero buffer | all-zero buffers |
    /// |------------------------|--------------|-----------------------|------------------|
    /// | MacBook Pro Microphone | 99 ms        | 99 ms                 | 0 of 375         |
    /// | AirPods Max, cold      | 143 ms       | 1422 ms               | 64 of 197        |
    ///
    /// Those 64 buffers are not quiet audio, they are `0` samples: macOS opens
    /// the capture immediately and pads it with digital silence until the
    /// HFP/SCO link finishes negotiating. Anything said in that window is not
    /// recorded at all. Pinning to the built-in microphone skips the
    /// negotiation entirely — the link stays in A2DP, so playback also keeps
    /// its music-quality codec for the length of the dictation.
    ///
    /// A shut lid withdraws that option, and the redirect is worse than useless
    /// then: in clamshell the built-in array delivers digital silence forever
    /// rather than slowly (552 of 552 and 366 of 366 all-zero buffers, measured
    /// twice; see ``LidState``), so the redirect trades a 551 ms headset warm-up
    /// for a microphone that never arrives. Liveness is keyed on the first
    /// non-zero sample, so the session stays in WARMING until the coordinator's
    /// warm-up deadline ends it.
    ///
    /// A user selection outranks all of it. The Settings picker stores a durable
    /// UID, and a device the user pointed at by name is their considered choice
    /// even when it is the Bluetooth headset this policy would otherwise avoid.
    /// A selection that does not currently resolve — the device is unplugged —
    /// falls back to the automatic policy rather than failing the dictation,
    /// the same stance ``MicrophoneCapture`` takes on a pinned UID that vanished
    /// between this decision and the session opening.
    ///
    /// Deliberately narrow. Only a Bluetooth default is redirected, and only to
    /// a built-in microphone that can actually record: a USB interface, an
    /// aggregate device or a virtual microphone is the user's considered choice
    /// and is left alone.
    static func preferredCaptureUID(selectedUID: String?) -> String? {
        preferredCaptureUID(
            selectedUID: selectedUID,
            systemDefault: systemDefault(),
            available: all(),
            lidIsClosed: LidState.isClosed()
        )
    }

    /// The policy itself, over values rather than over the HAL, so it is testable
    /// on a machine with no Bluetooth headset attached and with its lid open.
    static func preferredCaptureUID(
        selectedUID: String?,
        systemDefault: Device?,
        available: [Device],
        lidIsClosed: Bool
    ) -> String? {
        if let selectedUID, available.contains(where: { $0.uid == selectedUID }) {
            return selectedUID
        }
        guard let systemDefault, systemDefault.isBluetooth else { return nil }
        guard !lidIsClosed else { return nil }
        return available.first { $0.isBuiltIn }?.uid
    }

    /// One choosable input device, as the Settings picker needs it: the durable
    /// UID the selection is stored under and the human name the menu shows.
    public struct AvailableMicrophone: Equatable, Sendable {
        public var uid: String
        public var name: String

        public init(uid: String, name: String) {
            self.uid = uid
            self.name = name
        }
    }

    /// Every device currently able to record, for the Settings picker. Sorted by
    /// name then UID so the menu is stable across HAL enumeration order.
    public static func availableMicrophones() -> [AvailableMicrophone] {
        all()
            .map { AvailableMicrophone(uid: $0.uid, name: $0.name) }
            .sorted { ($0.name, $0.uid) < ($1.name, $1.uid) }
    }

    static func describe(_ deviceID: AudioObjectID) -> Device? {
        guard inputChannelCount(deviceID: deviceID) > 0,
            let uid = uid(deviceID: deviceID)
        else {
            return nil
        }
        return Device(
            id: deviceID,
            uid: uid,
            name: name(deviceID: deviceID) ?? uid,
            transportType: readUInt32(
                deviceID: deviceID,
                address: CoreAudioProperty.address(
                    kAudioDevicePropertyTransportType, scope: kAudioObjectPropertyScopeGlobal)
            ) ?? 0
        )
    }

    /// The durable input identity. Named apart from ``CoreAudioOutputDevice.uid`` on
    /// purpose: an input UID is what a capture session pins itself to, an output UID is
    /// what mute ownership is recorded against.
    private static func uid(deviceID: AudioObjectID) -> String? {
        readString(deviceID: deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    private static func name(deviceID: AudioObjectID) -> String? {
        readString(deviceID: deviceID, selector: kAudioObjectPropertyName)
    }

    private static func readString(deviceID: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        CoreAudioProperty.readString(
            CoreAudioProperty.address(selector, scope: kAudioObjectPropertyScopeGlobal), from: deviceID)
    }

    /// Input channels across every input stream. A device with none cannot
    /// record, which is how output-only hardware is filtered out.
    private static func inputChannelCount(deviceID: AudioObjectID) -> Int {
        var configurationAddress = CoreAudioProperty.address(
            kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectHasProperty(deviceID, &configurationAddress),
            AudioObjectGetPropertyDataSize(deviceID, &configurationAddress, 0, nil, &size) == noErr,
            size > 0
        else {
            return 0
        }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &configurationAddress, 0, nil, &size, raw) == noErr else {
            return 0
        }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func readUInt32(deviceID: AudioObjectID, address: AudioObjectPropertyAddress) -> UInt32? {
        CoreAudioProperty.read(address, from: deviceID, initialValue: UInt32(0))
    }
}
