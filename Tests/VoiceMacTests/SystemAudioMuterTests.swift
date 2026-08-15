import Foundation
import Testing

@testable import VoiceMac

@Suite("System audio muter")
struct SystemAudioMuterTests {
    @Test func unavailableDeviceKeepsDurableOwnershipForNextLaunch() throws {
        let flagURL = try makeDurableOwnershipFlag(deviceID: 41, deviceUID: "unavailable-output")
        defer { try? FileManager.default.removeItem(at: flagURL.deletingLastPathComponent()) }

        SystemAudioMuter.recoverDurableOwnershipIfNeeded(
            flagURL: flagURL,
            resolveDevice: { deviceID, deviceUID in
                #expect(deviceID == 41)
                #expect(deviceUID == "unavailable-output")
                return nil
            }
        )

        #expect(FileManager.default.fileExists(atPath: flagURL.path))
    }

    @Test func resolvableDeviceConsumesDurableOwnershipAfterRestoreAttempt() throws {
        let flagURL = try makeDurableOwnershipFlag(deviceID: 42, deviceUID: "available-output")
        defer { try? FileManager.default.removeItem(at: flagURL.deletingLastPathComponent()) }

        SystemAudioMuter.recoverDurableOwnershipIfNeeded(
            flagURL: flagURL,
            resolveDevice: { deviceID, deviceUID in
                #expect(deviceID == 42)
                #expect(deviceUID == "available-output")
                return 42
            }
        )

        #expect(!FileManager.default.fileExists(atPath: flagURL.path))
    }

    private func makeDurableOwnershipFlag(deviceID: UInt32, deviceUID: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SystemAudioMuterTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let flagURL = directory.appendingPathComponent("mute-owned.flag", isDirectory: false)
        let payload: [String: Any] = [
            "deviceID": deviceID,
            "deviceUID": deviceUID,
            "controls": [],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: flagURL, options: .atomic)
        return flagURL
    }
}
