import Foundation
import IOKit

/// Whether this Mac is running with its lid shut.
///
/// It exists for one measured reason: a closed lid does not muffle the built-in
/// microphone array, it silences it outright. Captured on an M4 Pro MacBook Pro
/// in clamshell operation, opening `BuiltInMicrophoneDevice` through the same
/// `AVCaptureSession` path ``MicrophoneCapture`` uses delivered 552 buffers in
/// six seconds and every sample of every buffer was exactly `0`, then 366 of
/// 366 on a repeat — while the AirPods Max input on the same host reached its
/// first non-zero sample in 551 ms.
///
/// Nothing in the audio stack says so. The device is enumerated, reports
/// `kAudioDevicePropertyDeviceIsAlive == 1`, `kAudioDevicePropertyMute == 0`,
/// data source `imic`, and `AVCaptureDevice.isSuspended == false`. The lid is
/// the only observable that predicts the silence, which is why a power-domain
/// property is being read from an audio decision.
enum LidState {
    /// True only on a Mac that has a lid and currently has it shut.
    ///
    /// Desktops never publish `AppleClamshellState`, and a machine with no lid
    /// has no closed lid: a missing property reads as open.
    static func isClosed() -> Bool {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(service) }
        let property = IORegistryEntryCreateCFProperty(
            service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return (property?.takeRetainedValue() as? Bool) ?? false
    }
}
