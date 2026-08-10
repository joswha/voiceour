import AVFoundation
import ApplicationServices
import CoreGraphics
import Foundation
import VoiceCore

public struct SystemPermissions: PermissionsChecking, Sendable {
    public init() {}

    public func microphone() -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }

    public func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    public func synthPaste() -> PermissionState {
        (CGPreflightPostEventAccess() || AXIsProcessTrusted()) ? .granted : .denied
    }

    public func requestSynthPaste() async -> Bool {
        if synthPaste() == .granted { return true }
        if CGRequestPostEventAccess() { return true }

        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public func accessibility() -> PermissionState {
        AXIsProcessTrusted() ? .granted : .denied
    }
}
