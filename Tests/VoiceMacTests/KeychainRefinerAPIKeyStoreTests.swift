import Dispatch
import Foundation
import Security
import Testing

@testable import VoiceMac

/// Covers keychain-domain selection, protected storage, migration, deletion, and
/// concurrency.
@Suite("Keychain Refiner API Key Store", .serialized)
struct KeychainRefinerAPIKeyStoreTests {
    /// The usable-keychain decision is process-wide, so a test that drives the
    /// entitlement fallback would otherwise poison every test after it.
    init() {
        KeychainRefinerAPIKeyStore.resetDataProtectionAvailabilityForTesting()
    }

    @Test func keychainSaveUsesProtectedDeviceBoundItem() throws {
        let keychain = FakeKeychainItemOperations()
        let store = KeychainRefinerAPIKeyStore(
            service: "test.refiner",
            account: "openai",
            keychain: keychain
        )

        try store.save(apiKey: "first")
        try store.save(apiKey: "second")

        #expect(keychain.apiKey(service: "test.refiner", account: "openai", dataProtection: true) == "second")
        #expect(
            keychain.addQueries.allSatisfy {
                $0[kSecUseDataProtectionKeychain as String] as? Bool == true
            })
        #expect(
            keychain.addQueries.allSatisfy {
                ($0[kSecAttrAccessible as String] as? String)
                    == (kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
            })
        #expect(
            keychain.updateAttributes.allSatisfy {
                ($0[kSecAttrAccessible as String] as? String)
                    == (kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
            })
    }

    @Test func keychainReadDoesNotBypassLockedProtectedItemWithLegacyFallback() {
        let keychain = FakeKeychainItemOperations()
        keychain.seed(
            apiKey: "protected-key",
            service: "test.refiner",
            account: "openai",
            dataProtection: true
        )
        keychain.seed(
            apiKey: "legacy-key",
            service: "test.refiner",
            account: "openai",
            dataProtection: false
        )
        keychain.nextCopyStatus = errSecInteractionNotAllowed
        let store = KeychainRefinerAPIKeyStore(
            service: "test.refiner",
            account: "openai",
            keychain: keychain
        )

        #expect(store.apiKey() == nil)
        #expect(keychain.copyQueries.count == 1)
    }

    @Test func keychainReadMigratesLegacyItemAfterVerifiedSave() {
        let keychain = FakeKeychainItemOperations()
        keychain.seed(
            apiKey: "installed-key",
            service: "test.refiner",
            account: "gemini",
            dataProtection: false
        )
        let store = KeychainRefinerAPIKeyStore(
            service: "test.refiner",
            account: "gemini",
            keychain: keychain
        )

        #expect(store.apiKey() == "installed-key")
        #expect(keychain.apiKey(service: "test.refiner", account: "gemini", dataProtection: true) == "installed-key")
        #expect(keychain.apiKey(service: "test.refiner", account: "gemini", dataProtection: false) == nil)
        #expect(keychain.copyQueries.count == 3)
        #expect(keychain.copyQueries[0][kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(keychain.copyQueries[1][kSecUseDataProtectionKeychain as String] == nil)
        #expect(keychain.copyQueries[2][kSecUseDataProtectionKeychain as String] as? Bool == true)
    }

    @Test func keychainMigrationPreservesProtectedItemCreatedByRace() {
        let keychain = FakeKeychainItemOperations()
        keychain.seed(
            apiKey: "new-key",
            service: "test.refiner",
            account: "gemini",
            dataProtection: true
        )
        keychain.seed(
            apiKey: "installed-key",
            service: "test.refiner",
            account: "gemini",
            dataProtection: false
        )
        keychain.nextCopyStatus = errSecItemNotFound
        let store = KeychainRefinerAPIKeyStore(
            service: "test.refiner",
            account: "gemini",
            keychain: keychain
        )

        #expect(store.apiKey() == "new-key")
        #expect(keychain.apiKey(service: "test.refiner", account: "gemini", dataProtection: true) == "new-key")
        #expect(keychain.apiKey(service: "test.refiner", account: "gemini", dataProtection: false) == nil)
        #expect(keychain.updateQueries.isEmpty)
    }

    @Test func keychainMigrationKeepsLegacyItemWhenProtectedSaveFails() {
        let keychain = FakeKeychainItemOperations()
        keychain.seed(
            apiKey: "installed-key",
            service: "test.refiner",
            account: "openrouter",
            dataProtection: false
        )
        keychain.nextAddStatus = errSecNotAvailable
        let store = KeychainRefinerAPIKeyStore(
            service: "test.refiner",
            account: "openrouter",
            keychain: keychain
        )

        #expect(store.apiKey() == "installed-key")
        #expect(keychain.apiKey(service: "test.refiner", account: "openrouter", dataProtection: true) == nil)
        #expect(
            keychain.apiKey(service: "test.refiner", account: "openrouter", dataProtection: false) == "installed-key")
        #expect(keychain.deleteQueries.isEmpty)
    }

    @Test func keychainMigrationDoesNotExposeLegacyKeyWhenProtectedKeychainIsLocked() {
        let keychain = FakeKeychainItemOperations()
        keychain.seed(
            apiKey: "installed-key",
            service: "test.refiner",
            account: "openrouter",
            dataProtection: false
        )
        keychain.nextAddStatus = errSecInteractionNotAllowed
        let store = KeychainRefinerAPIKeyStore(
            service: "test.refiner",
            account: "openrouter",
            keychain: keychain
        )

        #expect(store.apiKey() == nil)
        #expect(keychain.apiKey(service: "test.refiner", account: "openrouter", dataProtection: true) == nil)
        #expect(
            keychain.apiKey(service: "test.refiner", account: "openrouter", dataProtection: false) == "installed-key")
        #expect(keychain.deleteQueries.isEmpty)
    }

    @Test func keychainModernReadRetriesFailedLegacyCleanup() {
        let keychain = FakeKeychainItemOperations()
        keychain.seed(
            apiKey: "modern-key",
            service: "test.refiner",
            account: "openai",
            dataProtection: true
        )
        keychain.seed(
            apiKey: "legacy-key",
            service: "test.refiner",
            account: "openai",
            dataProtection: false
        )
        keychain.nextDeleteStatus = errSecInteractionNotAllowed
        let store = KeychainRefinerAPIKeyStore(
            service: "test.refiner",
            account: "openai",
            keychain: keychain
        )

        #expect(store.apiKey() == "modern-key")
        #expect(keychain.apiKey(service: "test.refiner", account: "openai", dataProtection: false) == "legacy-key")
        #expect(store.apiKey() == "modern-key")
        #expect(keychain.apiKey(service: "test.refiner", account: "openai", dataProtection: false) == nil)
        #expect(keychain.apiKey(service: "test.refiner", account: "openai", dataProtection: true) == "modern-key")
    }

    @Test func keychainDeleteCannotRaceWithMigrationAcrossStoreInstances() {
        let keychain = FakeKeychainItemOperations()
        keychain.seed(
            apiKey: "installed-key",
            service: "test.refiner",
            account: "gemini",
            dataProtection: false
        )
        let migrationPause = KeychainOperationPause()
        let deleteStarted = DispatchSemaphore(value: 0)
        let deleteEnteredOperations = DispatchSemaphore(value: 0)
        let outcomes = KeychainConcurrencyOutcomes()
        keychain.nextAddPause = migrationPause
        keychain.deleteEntrySignal = deleteEnteredOperations

        let reader = KeychainRefinerAPIKeyStore(
            service: "test.refiner",
            account: "gemini",
            keychain: keychain
        )
        let deleter = KeychainRefinerAPIKeyStore(
            service: "test.refiner",
            account: "gemini",
            keychain: keychain
        )

        let operations = DispatchGroup()
        operations.enter()
        DispatchQueue.global().async {
            outcomes.setReadValue(reader.apiKey())
            operations.leave()
        }
        #expect(migrationPause.entered.wait(timeout: .now() + .seconds(1)) == .success)

        operations.enter()
        DispatchQueue.global().async {
            deleteStarted.signal()
            do {
                try deleter.delete()
                outcomes.setDeleteSucceeded()
            } catch {
                outcomes.setDeleteError()
            }
            operations.leave()
        }
        #expect(deleteStarted.wait(timeout: .now() + .seconds(1)) == .success)
        #expect(deleteEnteredOperations.wait(timeout: .now() + .milliseconds(100)) == .timedOut)

        migrationPause.resume.signal()
        #expect(operations.wait(timeout: .now() + .seconds(1)) == .success)

        #expect(outcomes.readValue == "installed-key")
        #expect(outcomes.deleteSucceeded)
        #expect(keychain.apiKey(service: "test.refiner", account: "gemini", dataProtection: true) == nil)
        #expect(keychain.apiKey(service: "test.refiner", account: "gemini", dataProtection: false) == nil)
    }

    @Test func keychainSaveRecoversFromDuplicateUpdateRace() throws {
        let keychain = FakeKeychainItemOperations()
        keychain.seed(
            apiKey: "old-key",
            service: "test.refiner",
            account: "openai",
            dataProtection: true
        )
        keychain.removeDuplicateBeforeUpdate = true
        let store = KeychainRefinerAPIKeyStore(
            service: "test.refiner",
            account: "openai",
            keychain: keychain
        )

        try store.save(apiKey: "new-key")

        #expect(keychain.apiKey(service: "test.refiner", account: "openai", dataProtection: true) == "new-key")
        #expect(keychain.addQueries.count == 2)
        #expect(keychain.updateQueries.count == 1)
    }

    @Test func keychainDeleteClearsOnlyMatchingProviderFromBothKeychains() throws {
        let keychain = FakeKeychainItemOperations()
        for dataProtection in [true, false] {
            keychain.seed(
                apiKey: "openai-key",
                service: "test.refiner",
                account: "openai",
                dataProtection: dataProtection
            )
            keychain.seed(
                apiKey: "gemini-key",
                service: "test.refiner",
                account: "gemini",
                dataProtection: dataProtection
            )
        }
        let store = KeychainRefinerAPIKeyStore(
            service: "test.refiner",
            account: "openai",
            keychain: keychain
        )

        try store.delete()

        #expect(keychain.apiKey(service: "test.refiner", account: "openai", dataProtection: true) == nil)
        #expect(keychain.apiKey(service: "test.refiner", account: "openai", dataProtection: false) == nil)
        #expect(keychain.apiKey(service: "test.refiner", account: "gemini", dataProtection: true) == "gemini-key")
        #expect(keychain.apiKey(service: "test.refiner", account: "gemini", dataProtection: false) == "gemini-key")
        #expect(keychain.deleteQueries.count == 2)
        #expect(keychain.deleteQueries[0][kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(keychain.deleteQueries[1][kSecUseDataProtectionKeychain as String] == nil)
        #expect(
            keychain.deleteQueries.allSatisfy {
                $0[kSecAttrService as String] as? String == "test.refiner"
                    && $0[kSecAttrAccount as String] as? String == "openai"
            })
    }

    /// The shipped bundle is signed without a provisioning profile, so the data
    /// protection keychain answers `errSecMissingEntitlement` and the file-based
    /// keychain is the only store that can hold the key. Measured, not assumed:
    /// an ad-hoc binary gets -34018 from `SecItemAdd`, and faking the entitlement
    /// gets the process killed by AMFI.
    @Test func keychainSaveFallsBackToFileBasedStoreWhenEntitlementIsMissing() throws {
        let keychain = FakeKeychainItemOperations()
        keychain.nextAddStatus = errSecMissingEntitlement
        let store = KeychainRefinerAPIKeyStore(
            service: "test.refiner",
            account: "openai",
            keychain: keychain
        )

        try store.save(apiKey: "fallback-key")

        #expect(keychain.apiKey(service: "test.refiner", account: "openai", dataProtection: false) == "fallback-key")
        #expect(keychain.apiKey(service: "test.refiner", account: "openai", dataProtection: true) == nil)
        #expect(store.readAPIKey() == .found("fallback-key"))
    }

    /// Once the entitlement is known missing the store stops asking, so a read
    /// costs one round trip instead of two.
    @Test func keychainSkipsProtectedKeychainAfterEntitlementFailure() throws {
        let keychain = FakeKeychainItemOperations()
        keychain.nextAddStatus = errSecMissingEntitlement
        let store = KeychainRefinerAPIKeyStore(
            service: "test.refiner",
            account: "openai",
            keychain: keychain
        )
        try store.save(apiKey: "fallback-key")

        #expect(store.apiKey() == "fallback-key")
        #expect(keychain.copyQueries.count == 1)
        #expect(keychain.copyQueries[0][kSecUseDataProtectionKeychain as String] == nil)
    }

    @Test func keychainReadDistinguishesAbsentItemFromUnavailableKeychain() {
        let keychain = FakeKeychainItemOperations()
        let store = KeychainRefinerAPIKeyStore(
            service: "test.refiner",
            account: "openai",
            keychain: keychain
        )

        #expect(store.readAPIKey() == .absent)

        keychain.nextCopyStatus = errSecInteractionNotAllowed
        #expect(store.readAPIKey() == .unavailable(errSecInteractionNotAllowed))
    }

    @Test func keychainSavePropagatesUpdateFailure() {
        let keychain = FakeKeychainItemOperations()
        keychain.seed(
            apiKey: "old-key",
            service: "test.refiner",
            account: "openai",
            dataProtection: true
        )
        keychain.nextUpdateStatus = errSecInteractionNotAllowed
        let store = KeychainRefinerAPIKeyStore(
            service: "test.refiner",
            account: "openai",
            keychain: keychain
        )

        #expect(throws: KeychainError.status(errSecInteractionNotAllowed)) {
            try store.save(apiKey: "new-key")
        }
        #expect(keychain.apiKey(service: "test.refiner", account: "openai", dataProtection: true) == "old-key")
    }

    @Test func keychainDeletePropagatesFailureAndStillClearsBothStores() {
        let keychain = FakeKeychainItemOperations()
        for dataProtection in [true, false] {
            keychain.seed(
                apiKey: "openai-key",
                service: "test.refiner",
                account: "openai",
                dataProtection: dataProtection
            )
        }
        keychain.nextDeleteStatus = errSecInteractionNotAllowed
        let store = KeychainRefinerAPIKeyStore(
            service: "test.refiner",
            account: "openai",
            keychain: keychain
        )

        #expect(throws: KeychainError.status(errSecInteractionNotAllowed)) {
            try store.delete()
        }
        // The protected delete failed, but the file-based copy must not survive
        // just because the first store answered badly.
        #expect(keychain.deleteQueries.count == 2)
        #expect(keychain.apiKey(service: "test.refiner", account: "openai", dataProtection: false) == nil)
    }
}

private final class FakeKeychainItemOperations: KeychainItemOperating, @unchecked Sendable {
    private struct ItemID: Hashable {
        let service: String
        let account: String
        let dataProtection: Bool
    }

    private var items: [ItemID: Data] = [:]

    var nextAddStatus: OSStatus?
    var nextCopyStatus: OSStatus?
    var nextDeleteStatus: OSStatus?
    var nextUpdateStatus: OSStatus?
    var nextAddPause: KeychainOperationPause?
    var deleteEntrySignal: DispatchSemaphore?
    var removeDuplicateBeforeUpdate = false

    private(set) var copyQueries: [[String: Any]] = []
    private(set) var addQueries: [[String: Any]] = []
    private(set) var updateQueries: [[String: Any]] = []
    private(set) var updateAttributes: [[String: Any]] = []
    private(set) var deleteQueries: [[String: Any]] = []

    func seed(
        apiKey: String,
        service: String,
        account: String,
        dataProtection: Bool
    ) {
        items[
            ItemID(
                service: service,
                account: account,
                dataProtection: dataProtection
            )] = Data(apiKey.utf8)
    }

    func apiKey(
        service: String,
        account: String,
        dataProtection: Bool
    ) -> String? {
        let data = items[
            ItemID(
                service: service,
                account: account,
                dataProtection: dataProtection
            )]
        return data.flatMap { String(data: $0, encoding: .utf8) }
    }

    func copyMatching(
        _ query: CFDictionary,
        result: UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus {
        let query = dictionary(query)
        copyQueries.append(query)
        if let status = nextCopyStatus {
            nextCopyStatus = nil
            return status
        }
        guard let id = itemID(query), let data = items[id] else {
            return errSecItemNotFound
        }
        result?.pointee = data as CFData
        return errSecSuccess
    }

    func add(_ attributes: CFDictionary) -> OSStatus {
        let attributes = dictionary(attributes)
        addQueries.append(attributes)
        if let pause = nextAddPause {
            nextAddPause = nil
            pause.entered.signal()
            pause.resume.wait()
        }
        if let status = nextAddStatus {
            nextAddStatus = nil
            return status
        }
        guard let id = itemID(attributes),
            let data = attributes[kSecValueData as String] as? Data
        else {
            return errSecParam
        }
        guard items[id] == nil else {
            if removeDuplicateBeforeUpdate {
                removeDuplicateBeforeUpdate = false
                items[id] = nil
            }
            return errSecDuplicateItem
        }
        items[id] = data
        return errSecSuccess
    }

    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus {
        let query = dictionary(query)
        let attributes = dictionary(attributes)
        updateQueries.append(query)
        updateAttributes.append(attributes)
        if let status = nextUpdateStatus {
            nextUpdateStatus = nil
            return status
        }
        guard let id = itemID(query), items[id] != nil else {
            return errSecItemNotFound
        }
        guard let data = attributes[kSecValueData as String] as? Data else {
            return errSecParam
        }
        items[id] = data
        return errSecSuccess
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        let query = dictionary(query)
        deleteQueries.append(query)
        deleteEntrySignal?.signal()
        if let status = nextDeleteStatus {
            nextDeleteStatus = nil
            return status
        }
        guard let id = itemID(query), items.removeValue(forKey: id) != nil else {
            return errSecItemNotFound
        }
        return errSecSuccess
    }

    private func itemID(_ query: [String: Any]) -> ItemID? {
        guard let service = query[kSecAttrService as String] as? String,
            let account = query[kSecAttrAccount as String] as? String
        else {
            return nil
        }
        return ItemID(
            service: service,
            account: account,
            dataProtection: query[kSecUseDataProtectionKeychain as String] as? Bool == true
        )
    }

    private func dictionary(_ dictionary: CFDictionary) -> [String: Any] {
        dictionary as NSDictionary as? [String: Any] ?? [:]
    }
}

private final class KeychainOperationPause: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
}

private final class KeychainConcurrencyOutcomes: @unchecked Sendable {
    private let lock = NSLock()
    private var storedReadValue: String?
    private var storedDeleteSucceeded = false

    var readValue: String? {
        lock.withLock { storedReadValue }
    }

    var deleteSucceeded: Bool {
        lock.withLock { storedDeleteSucceeded }
    }

    func setReadValue(_ value: String?) {
        lock.withLock {
            storedReadValue = value
        }
    }

    func setDeleteSucceeded() {
        lock.withLock {
            storedDeleteSucceeded = true
        }
    }

    func setDeleteError() {
        lock.withLock {
            storedDeleteSucceeded = false
        }
    }
}
