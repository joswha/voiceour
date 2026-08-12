import CoreAudio
import Foundation
import VoiceCore

/// One property write the muter is responsible for undoing. It doubles as the
/// on-disk crash-recovery record, so in-memory and durable ownership can never
/// describe different things.
private struct MuteControl: Codable, Equatable {
    enum Kind: String, Codable {
        case mute
        case volume
    }

    var kind: Kind
    var element: UInt32
    var priorUInt32: UInt32?
    var priorFloat32: Float32?
}

private struct MuteOwnership: Codable, Equatable {
    var deviceID: UInt32
    /// CoreAudio recycles device IDs across reboots and re-plugs, so recovery
    /// after a crash matches on the UID and falls back to the ID only for a
    /// device that publishes none.
    var deviceUID: String?
    var controls: [MuteControl]
}

private struct VolumeRamp: Equatable {
    var element: UInt32
    var start: Float32
    var end: Float32
}

/// Silences the current default output device for the length of a capture and
/// restores it afterwards.
///
/// Three measured facts shape this type:
///
/// * **Which control exists is per device, not per device class.** MacBook Pro
///   Speakers expose a settable main mute *and* a settable main volume; AirPods
///   Max expose a settable main mute but **no** main volume, only per-channel
///   volume; a DisplayPort monitor exposes neither and cannot be silenced at
///   all. So the muter probes for controls instead of assuming a shape, and
///   reports `false` for a device that offers none.
/// * **A hard mute is an audible cut.** Volume ramps to zero over
///   ``fadeDuration`` before the mute lands and ramps back after it lifts, so
///   both edges of a capture read as a fade rather than a glitch.
/// * **Transport type is not a proxy for "worth muting."** This used to skip
///   every non-built-in device unless the user found a second setting, which
///   made the whole feature a silent no-op on the headphones people actually
///   wear while dictating. Whatever the default output device is, that is what
///   the user hears, so that is what gets muted.
public actor SystemAudioMuter: SystemAudioMuting {
    /// Fade time at each edge of a capture. Long enough to remove the click,
    /// short enough that the stop path does not feel like it stalled.
    private static let fadeDuration: Duration = .milliseconds(120)
    private static let fadeSteps = 8

    private var ownership: MuteOwnership?

    /// Bumped on entry to every public operation. A fade suspends between steps
    /// and an actor is reentrant across suspensions, so each step checks that
    /// it is still the newest operation before writing. Without it, a restore
    /// arriving mid-fade is overwritten by the remainder of that fade, leaving
    /// the device silent with no ownership left to undo it.
    private var generation: UInt64 = 0

    public init() {
        Self.recoverDurableOwnershipIfNeeded()
    }

    public func mute() async -> Bool {
        if ownership != nil {
            await restore()
        }
        let generation = beginOperation()

        guard let deviceID = CoreAudioOutputDevice.defaultDevice() else {
            return false
        }
        let volumeControls = CoreAudioOutputDevice.settableVolumeControls(deviceID: deviceID)
        let priorMute = CoreAudioOutputDevice.settableMute(deviceID: deviceID)
        guard let newOwnership = Self.ownership(deviceID: deviceID, volumes: volumeControls, mute: priorMute),
            // Persisted before the first write: a crash between here and the
            // restore has to leave a trail the next launch can undo.
            Self.writeDurableOwnershipFlag(newOwnership)
        else {
            return false
        }

        var applied = await ramp(
            deviceID: deviceID,
            ramps: volumeControls.map { VolumeRamp(element: $0.element, start: $0.value, end: 0) },
            generation: generation
        )
        if priorMute != nil {
            // Left operand first, and always evaluated: `||` short-circuits
            // rightwards, so the write happens whatever the ramp reported.
            applied =
                CoreAudioOutputDevice.setMute(
                    deviceID: deviceID, element: kAudioObjectPropertyElementMain, value: 1) || applied
        }

        guard applied else {
            Self.removeDurableOwnershipFlag()
            return false
        }
        ownership = newOwnership
        return true
    }

    public func restore() async {
        guard let ownership else {
            Self.removeDurableOwnershipFlag()
            return
        }

        let generation = beginOperation()
        self.ownership = nil
        let deviceID = AudioObjectID(ownership.deviceID)

        // The mute lifts first and the volume ramps back under it; the other
        // order spends the whole fade behind a mute and still ends in a step.
        Self.restoreMuteControls(ownership.controls, deviceID: deviceID)
        _ = await ramp(
            deviceID: deviceID,
            ramps: Self.volumeRamps(forRestoring: ownership.controls, deviceID: deviceID, tolerant: false),
            generation: generation
        )
        Self.removeDurableOwnershipFlag()
    }

    private func beginOperation() -> UInt64 {
        generation &+= 1
        return generation
    }

    /// Drives every ramp in lockstep, one step per tick. Returns whether any
    /// write landed, which is what tells `mute()` the device actually moved.
    private func ramp(deviceID: AudioObjectID, ramps: [VolumeRamp], generation: UInt64) async -> Bool {
        guard !ramps.isEmpty else {
            return false
        }

        var applied = false
        let stepDelay = Self.fadeDuration / Self.fadeSteps
        for step in 1...Self.fadeSteps {
            guard generation == self.generation else {
                return applied
            }

            let progress = Float32(step) / Float32(Self.fadeSteps)
            for ramp in ramps {
                let value = ramp.start + (ramp.end - ramp.start) * progress
                if CoreAudioOutputDevice.setVolume(deviceID: deviceID, element: ramp.element, value: value) {
                    applied = true
                }
            }

            if step < Self.fadeSteps {
                try? await Task.sleep(for: stepDelay)
            }
        }
        return applied
    }

    private static func ownership(
        deviceID: AudioObjectID,
        volumes: [CoreAudioOutputDevice.VolumeControl],
        mute priorMute: UInt32?
    ) -> MuteOwnership? {
        var controls = volumes.map {
            MuteControl(kind: .volume, element: $0.element, priorUInt32: nil, priorFloat32: $0.value)
        }
        if let priorMute {
            controls.append(
                MuteControl(
                    kind: .mute,
                    element: kAudioObjectPropertyElementMain,
                    priorUInt32: priorMute,
                    priorFloat32: nil
                )
            )
        }
        guard !controls.isEmpty else {
            return nil
        }
        return MuteOwnership(
            deviceID: UInt32(deviceID),
            deviceUID: CoreAudioOutputDevice.uid(deviceID: deviceID),
            controls: controls
        )
    }

    /// Reasserts each owned mute, but only where the device is still muted: if
    /// the user unmuted while VoiceOour held the device, the user wins.
    private static func restoreMuteControls(_ controls: [MuteControl], deviceID: AudioObjectID) {
        for control in controls where control.kind == .mute {
            guard let priorValue = control.priorUInt32,
                CoreAudioOutputDevice.mute(deviceID: deviceID, element: control.element) == 1
            else {
                continue
            }
            CoreAudioOutputDevice.setMute(deviceID: deviceID, element: control.element, value: priorValue)
        }
    }

    /// The volume half of a restore, skipping any control the user has moved.
    ///
    /// `tolerant` is the whole difference between the two callers. A live
    /// restore knows the fade ran to completion, so anything other than zero is
    /// the user's doing and is left alone. Crash recovery has no such
    /// knowledge: the process may have died mid-ramp at any value between zero
    /// and the prior one, so any value at or below the prior one is ours.
    private static func volumeRamps(
        forRestoring controls: [MuteControl],
        deviceID: AudioObjectID,
        tolerant: Bool
    ) -> [VolumeRamp] {
        controls.compactMap { control in
            guard control.kind == .volume,
                let priorValue = control.priorFloat32,
                let currentValue = CoreAudioOutputDevice.volume(deviceID: deviceID, element: control.element)
            else {
                return nil
            }

            let isOurs =
                tolerant
                ? currentValue <= priorValue + Float32.ulpOfOne
                : abs(currentValue) <= Float32.ulpOfOne
            guard isOurs else {
                return nil
            }
            return VolumeRamp(element: control.element, start: currentValue, end: priorValue)
        }
    }

    private static func writeDurableOwnershipFlag(_ ownership: MuteOwnership) -> Bool {
        guard let flagURL = durableOwnershipFlagURL else {
            return false
        }

        do {
            try FileManager.default.createDirectory(
                at: flagURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(ownership)
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

    /// Undoes a mute left behind by a crashed run. Restores in one step rather
    /// than a fade: nothing is playing yet at launch, and a fade here would
    /// only widen the window in which a second crash strands the device again.
    public static func recoverDurableOwnershipIfNeeded() {
        guard let flagURL = durableOwnershipFlagURL,
            let data = try? Data(contentsOf: flagURL)
        else {
            return
        }
        defer { removeDurableOwnershipFlag() }
        guard let ownership = try? JSONDecoder().decode(MuteOwnership.self, from: data),
            let deviceID = recoveryDeviceID(for: ownership)
        else {
            return
        }

        restoreMuteControls(ownership.controls, deviceID: deviceID)
        for ramp in volumeRamps(forRestoring: ownership.controls, deviceID: deviceID, tolerant: true) {
            CoreAudioOutputDevice.setVolume(deviceID: deviceID, element: ramp.element, value: ramp.end)
        }
    }

    /// Resolves the recorded device, refusing to write to a recycled ID: after
    /// a reboot that number can name hardware VoiceOour never touched.
    private static func recoveryDeviceID(for ownership: MuteOwnership) -> AudioObjectID? {
        let recordedID = AudioObjectID(ownership.deviceID)
        guard let uid = ownership.deviceUID else {
            return recordedID
        }
        if CoreAudioOutputDevice.uid(deviceID: recordedID) == uid {
            return recordedID
        }
        return CoreAudioOutputDevice.device(forUID: uid)
    }

    private static var durableOwnershipFlagURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("VoiceOour", isDirectory: true)
            .appendingPathComponent("mute-owned.flag", isDirectory: false)
    }
}
