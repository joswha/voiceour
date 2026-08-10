import Foundation
import Security

/// The optional refiner API key, held in the user's keychain.
///
/// macOS has two keychain implementations and only one of them is reachable from
/// this app. The data protection keychain (`kSecUseDataProtectionKeychain`) is
/// the modern one, but on macOS it resolves an item's access group from a
/// code-signing entitlement that must itself be authorised by a provisioning
/// profile. VoiceOour ships neither: `Resources/VoiceOour.entitlements` is
/// audio-input only and `scripts/bundle.sh` embeds no profile, so `SecItemAdd`
/// against that keychain answers `errSecMissingEntitlement` (-34018) — and
/// adding the entitlement to an ad-hoc signature instead gets the process killed
/// by AMFI ("adhoc signed but contains restricted entitlements"). The file-based
/// keychain has no such prerequisite and is the supported store for a
/// non-sandboxed, profile-less Mac app.
///
/// So each operation tries the data protection keychain first and falls back to
/// the file-based one on `errSecMissingEntitlement` alone. Today that fallback
/// always engages. Keying it on exactly one status keeps it from masking any
/// other failure, and if the bundle ever gains a provisioning profile the same
/// code promotes the item on the next read with no separate migration.
public struct KeychainRefinerAPIKeyStore: RefinerAPIKeyProviding, Sendable {
    public let service: String
    public let account: String

    private static let operationLock = NSLock()

    /// Whether the data protection keychain has answered without an entitlement
    /// complaint so far. Read and written only while `operationLock` is held.
    private static var dataProtectionUsable = true

    private let keychain: any KeychainItemOperating

    /// `account` is deliberately required. Every caller keys the item on the
    /// selected refiner, so a defaulted account would silently read a different
    /// provider's key.
    public init(service: String = "com.voiceoour.app.refiner", account: String) {
        self.init(
            service: service,
            account: account,
            keychain: SystemKeychainItemOperations()
        )
    }

    init(
        service: String,
        account: String,
        keychain: any KeychainItemOperating
    ) {
        self.service = service
        self.account = account
        self.keychain = keychain
    }

    public func apiKey() -> String? {
        guard case .found(let apiKey) = readAPIKey() else { return nil }
        return apiKey
    }

    public func readAPIKey() -> RefinerAPIKeyReadOutcome {
        Self.operationLock.withLock {
            readLocked()
        }
    }

    private func readLocked() -> RefinerAPIKeyReadOutcome {
        if Self.dataProtectionUsable {
            switch readData(query: dataProtectionQuery) {
            case .found(let data):
                guard let apiKey = String(data: data, encoding: .utf8) else {
                    return .unavailable(errSecDecode)
                }
                // A protected item outranks any file-based leftover.
                _ = keychain.delete(fileBasedQuery as CFDictionary)
                return .found(apiKey)
            case .notFound:
                break
            case .failed(errSecMissingEntitlement):
                Self.dataProtectionUsable = false
            case .failed(let status):
                return .unavailable(status)
            }
        }

        switch readData(query: fileBasedQuery) {
        case .found(let data):
            guard let fileBasedKey = String(data: data, encoding: .utf8) else {
                return .unavailable(errSecDecode)
            }
            switch promoteToDataProtectionLocked(data) {
            case .protectedValue(let apiKey):
                return .found(apiKey)
            case .keepFileBased:
                return .found(fileBasedKey)
            case .unavailable(let status):
                return .unavailable(status)
            }
        case .notFound:
            return .absent
        case .failed(let status):
            return .unavailable(status)
        }
    }

    public func save(apiKey: String) throws {
        try Self.operationLock.withLock {
            try saveLocked(data: Data(apiKey.utf8))
        }
    }

    private func saveLocked(data: Data) throws {
        if Self.dataProtectionUsable {
            switch upsertLocked(query: dataProtectionQuery, addQuery: dataProtectionAddQuery(data: data), data: data) {
            case .success:
                _ = keychain.delete(fileBasedQuery as CFDictionary)
                return
            case .missingEntitlement:
                Self.dataProtectionUsable = false
            case .failure(let status):
                throw KeychainError.status(status)
            }
        }

        switch upsertLocked(query: fileBasedQuery, addQuery: fileBasedAddQuery(data: data), data: data) {
        case .success:
            return
        case .missingEntitlement:
            throw KeychainError.status(errSecMissingEntitlement)
        case .failure(let status):
            throw KeychainError.status(status)
        }
    }

    public func delete() throws {
        try Self.operationLock.withLock {
            try deleteLocked()
        }
    }

    private func deleteLocked() throws {
        // Always attempt both stores, then report the first genuine failure, so a
        // failure in one never leaves the other copy silently behind.
        var failure: OSStatus?
        for query in [dataProtectionQuery, fileBasedQuery] {
            switch keychain.delete(query as CFDictionary) {
            case errSecSuccess, errSecItemNotFound:
                continue
            case errSecMissingEntitlement:
                Self.dataProtectionUsable = false
            case let status:
                failure = failure ?? status
            }
        }
        if let failure {
            throw KeychainError.status(failure)
        }
    }

    private enum Promotion {
        /// The protected keychain answered; its value outranks the file-based one.
        case protectedValue(String)
        /// Promotion did not happen; the file-based value still stands.
        case keepFileBased
        case unavailable(OSStatus)
    }

    /// Copy a file-based item into the data protection keychain when that
    /// keychain is usable. The file-based copy is only dropped once the protected
    /// one reads back, so an uncertain status never destroys the user's only key.
    private func promoteToDataProtectionLocked(_ data: Data) -> Promotion {
        guard Self.dataProtectionUsable else { return .keepFileBased }

        for attempt in 0..<2 {
            let addStatus = keychain.add(dataProtectionAddQuery(data: data) as CFDictionary)
            switch addStatus {
            case errSecSuccess, errSecDuplicateItem:
                switch readData(query: dataProtectionQuery) {
                case .found(let protectedData):
                    guard let apiKey = String(data: protectedData, encoding: .utf8) else {
                        return .keepFileBased
                    }
                    _ = keychain.delete(fileBasedQuery as CFDictionary)
                    return .protectedValue(apiKey)
                case .notFound where addStatus == errSecDuplicateItem && attempt == 0:
                    // Something removed the duplicate between the add and the
                    // read back; take the add again.
                    continue
                case .notFound:
                    return .keepFileBased
                case .failed(let status):
                    return .unavailable(status)
                }
            case errSecMissingEntitlement:
                Self.dataProtectionUsable = false
                return .keepFileBased
            case errSecInteractionNotAllowed:
                // The protected store exists but is locked, so it may already hold
                // a newer key than this file-based leftover. Answer with neither
                // rather than risk sending a superseded credential.
                return .unavailable(errSecInteractionNotAllowed)
            default:
                return .keepFileBased
            }
        }

        return .keepFileBased
    }

    private enum UpsertOutcome {
        case success
        case missingEntitlement
        case failure(OSStatus)
    }

    private func upsertLocked(
        query: [String: Any],
        addQuery: [String: Any],
        data: Data
    ) -> UpsertOutcome {
        var updateAttributes: [String: Any] = [kSecValueData as String: data]
        // The file-based keychain ignores `kSecAttrAccessible`; sending it there
        // would only imply a protection this store cannot deliver.
        if query[kSecUseDataProtectionKeychain as String] != nil {
            updateAttributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }

        for attempt in 0..<2 {
            let addStatus = keychain.add(addQuery as CFDictionary)
            switch addStatus {
            case errSecSuccess:
                return .success
            case errSecDuplicateItem:
                let updateStatus = keychain.update(
                    query as CFDictionary,
                    attributes: updateAttributes as CFDictionary
                )
                switch updateStatus {
                case errSecSuccess:
                    return .success
                case errSecItemNotFound where attempt == 0:
                    // Deleted between the add and the update; take the add again.
                    continue
                default:
                    return .failure(updateStatus)
                }
            case errSecMissingEntitlement:
                return .missingEntitlement
            default:
                return .failure(addStatus)
            }
        }

        return .failure(errSecItemNotFound)
    }

    private func readData(query: [String: Any]) -> KeychainReadResult {
        var item: CFTypeRef?
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let status = keychain.copyMatching(query as CFDictionary, result: &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return .failed(errSecDecode) }
            return .found(data)
        case errSecItemNotFound:
            return .notFound
        default:
            return .failed(status)
        }
    }

    private func dataProtectionAddQuery(data: Data) -> [String: Any] {
        var query = dataProtectionQuery
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        query[kSecValueData as String] = data
        return query
    }

    private func fileBasedAddQuery(data: Data) -> [String: Any] {
        var query = fileBasedQuery
        query[kSecValueData as String] = data
        return query
    }

    private var dataProtectionQuery: [String: Any] {
        var query = baseQuery
        query[kSecUseDataProtectionKeychain as String] = true
        return query
    }

    private var fileBasedQuery: [String: Any] {
        baseQuery
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Test seam: the usable-keychain decision is process-wide, so a test that
    /// drives the entitlement fallback has to be able to put it back.
    static func resetDataProtectionAvailabilityForTesting() {
        operationLock.withLock { dataProtectionUsable = true }
    }
}

protocol KeychainItemOperating: Sendable {
    func copyMatching(
        _ query: CFDictionary,
        result: UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus
    func add(_ attributes: CFDictionary) -> OSStatus
    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus
    func delete(_ query: CFDictionary) -> OSStatus
}

private struct SystemKeychainItemOperations: KeychainItemOperating {
    func copyMatching(
        _ query: CFDictionary,
        result: UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus {
        SecItemCopyMatching(query, result)
    }

    func add(_ attributes: CFDictionary) -> OSStatus {
        SecItemAdd(attributes, nil)
    }

    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus {
        SecItemUpdate(query, attributes)
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        SecItemDelete(query)
    }
}

private enum KeychainReadResult {
    case found(Data)
    case notFound
    case failed(OSStatus)
}

enum KeychainError: Error, Equatable {
    case status(OSStatus)
}
