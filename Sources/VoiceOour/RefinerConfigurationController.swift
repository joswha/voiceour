import CryptoKit
import Foundation
import VoiceCore
import VoiceMac

/// Refiner configuration: which backend is bound to the current settings, where
/// its API key comes from, whether it is reachable, and the Oh My Pi onboarding
/// and provider-status flows.
///
/// Extracted from `DictationCoordinator` as an extension rather than a separate
/// collaborator because every member here publishes to the coordinator's
/// main-actor UI state. Members that were `private` are now `internal`: Swift
/// scopes `private` to one file, so an extension in another file cannot see them.
@MainActor
extension DictationCoordinator {
    struct RefinerIdentity: Equatable {
        let enabled: Bool
        let provider: RefinerProvider
        let endpoint: String
        let model: String
        let timeoutMs: Int

        init(settings: VoiceCore.Settings) {
            enabled = settings.refinerEnabled
            provider = settings.refinerProvider
            endpoint = RefinerResolved.baseURL(settings)
            model = RefinerResolved.model(settings)
            timeoutMs = settings.refinerTimeoutMs
        }

        var label: String {
            "\(provider.rawValue):\(model)"
        }

        var isCloud: Bool {
            provider != .appleOnDevice
        }
    }

    struct RefinerBinding {
        let backend: TranscriptRefining
        let identity: RefinerIdentity
        let configurationGeneration: AsyncGenerationGate.Token
    }

    nonisolated static func keychainAccount(
        for provider: RefinerProvider,
        endpoint: String
    ) -> String {
        let baseAccount = "api-key-\(provider.rawValue)"
        guard provider == .custom else { return baseAccount }
        let digest = SHA256.hash(data: Data(normalizedEndpoint(endpoint).utf8))
        let endpointDigest = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "\(baseAccount)-\(endpointDigest)"
    }

    private nonisolated static func normalizedEndpoint(_ endpoint: String) -> String {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed) else {
            return trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        let normalized = components.string ?? trimmed
        return normalized.hasSuffix("/") ? String(normalized.dropLast()) : normalized
    }

    nonisolated static func keychainStore(
        for provider: RefinerProvider,
        endpoint: String
    ) -> KeychainRefinerAPIKeyStore {
        KeychainRefinerAPIKeyStore(account: keychainAccount(for: provider, endpoint: endpoint))
    }

    nonisolated static func envKeyProvider(
        for provider: RefinerProvider,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> EnvRefinerAPIKeyProvider {
        // Prefer the provider-specific variable because the narrower credential wins.
        EnvRefinerAPIKeyProvider(
            names: [provider.apiKeyEnvName].compactMap { $0 } + ["VOICEOOUR_REFINER_API_KEY"],
            environment: environment
        )
    }

    nonisolated static func keyProvider(
        for provider: RefinerProvider,
        endpoint: String
    ) -> CompositeRefinerAPIKeyProvider {
        CompositeRefinerAPIKeyProvider([
            keychainStore(for: provider, endpoint: endpoint),
            envKeyProvider(for: provider),
        ])
    }

    nonisolated static func detectKeySource(
        for provider: RefinerProvider,
        endpoint: String
    ) -> RefinerKeySource {
        // Mirror the fall-through rule the request path uses, so this label can
        // never advertise a credential the refiner will refuse to send: an
        // unreachable keychain is reported as no key, not as the environment's.
        switch keychainStore(for: provider, endpoint: endpoint).readAPIKey() {
        case .found:
            return .keychain
        case .unavailable:
            return .none
        case .absent:
            guard case .found = envKeyProvider(for: provider).readAPIKey() else { return .none }
            return .environment
        }
    }

    func currentRefinerBinding() -> RefinerBinding {
        let desiredIdentity = RefinerIdentity(settings: settings)
        if let refinerFactory, boundRefinerIdentity != desiredIdentity {
            refiner = refinerFactory(settings)
            boundRefinerIdentity = desiredIdentity
        }
        return RefinerBinding(
            backend: refiner,
            identity: boundRefinerIdentity ?? desiredIdentity,
            configurationGeneration: generations.currentToken(.refinerConfiguration)
        )
    }

    func commitReachability(
        _ result: RefinerReachability,
        identity: RefinerIdentity,
        configurationGeneration: AsyncGenerationGate.Token,
        requestGeneration: AsyncGenerationGate.Token
    ) -> Bool {
        guard generations.isCurrent(configurationGeneration),
            generations.isCurrent(requestGeneration),
            identity == RefinerIdentity(settings: settings)
        else {
            return false
        }
        refinerReachability = result
        return true
    }

    func applyRefinerReachabilityFailureIfCurrent(
        _ reason: String,
        binding: RefinerBinding
    ) {
        guard binding.identity.isCloud,
            generations.isCurrent(binding.configurationGeneration),
            binding.identity == RefinerIdentity(settings: settings)
        else {
            return
        }

        let verdict: RefinerReachability
        switch reason {
        case "http_401", "http_403":
            verdict = .unauthorized
        case "http_400":
            verdict = .failed("HTTP 400")
        case "http_404":
            verdict = .failed("HTTP 404")
        default:
            return
        }
        generations.invalidate(.reachability)
        refinerReachability = verdict
    }

    public func saveRefinerAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = RefinerResolved.baseURL(settings)
        let store = Self.keychainStore(for: settings.refinerProvider, endpoint: endpoint)
        do {
            if trimmed.isEmpty {
                try store.delete()
            } else {
                try store.save(apiKey: trimmed)
            }
            keychainError = nil
            refinerKeySource = keySourceProvider(settings.refinerProvider, endpoint)
            generations.invalidate(.refinerConfiguration)
            generations.invalidate(.reachability)
            refinerReachability = .unknown
        } catch {
            keychainError = "Keychain update failed: \(error)"
        }
    }

    public func selectRefinerProvider(_ provider: RefinerProvider) {
        let currentModel = settings.refinerModel
        let isProviderSuggestedModel = RefinerProvider.allCases.contains { candidate in
            candidate.suggestedModels.contains(currentModel)
        }
        settings.refinerProvider = provider
        if currentModel.isEmpty || isProviderSuggestedModel {
            settings.refinerModel = ""
        }
        saveSettings()
        refinerKeySource = keySourceProvider(provider, RefinerResolved.baseURL(settings))
    }

    /// Refreshes the redacted provider/account inventory that `omp usage`
    /// exposes. The probe returns counts only; OAuth credentials stay inside OMP.
    @discardableResult
    public func refreshOmpProviderStatuses(timeoutMs: Int = 30_000) async -> Bool {
        let requestGeneration = generations.begin(.providerStatus)
        let previousState = ompProviderStatusState
        ompProviderStatusState = .checking
        let environment = ProcessInfo.processInfo.environment
        let omp = OmpExecutable.resolve(explicitPath: environment["VOICEOOUR_OMP_BIN"])

        do {
            let snapshot = try await ompProviderStatusProbe(
                omp.url,
                omp.prefix,
                max(timeoutMs, 1)
            )
            guard generations.isCurrent(requestGeneration) else { return false }
            ompProviderConnections = snapshot.connections
            ompProviderStatusState = .loaded
            return true
        } catch is CancellationError {
            guard generations.isCurrent(requestGeneration) else { return false }
            ompProviderStatusState = previousState
            return false
        } catch {
            guard generations.isCurrent(requestGeneration) else { return false }
            let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            ompProviderStatusState = .failed(detail)
            return false
        }
    }

    /// Opens OMP's own provider login in a temporary Terminal session, waits
    /// for it to finish, then selects a matching model from the same hermetic
    /// catalog the refiner uses. OAuth tokens remain entirely inside OMP.
    @discardableResult
    public func startOmpOnboarding(_ subscription: OmpSubscription) async -> Bool {
        guard settings.refinerProvider == .omp, !ompOnboardingState.isInFlight else {
            return false
        }

        ompOnboardingState = .opening(subscription)
        let session: OmpOnboardingSession
        do {
            session = try await ompOnboardingStart(subscription)
        } catch is CancellationError {
            ompOnboardingState = .cancelled(subscription)
            return false
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            ompOnboardingState = .failed(subscription, detail)
            return false
        }

        ompOnboardingState = .terminalOpen(subscription)
        switch await ompOnboardingFinish(session) {
        case .cancelled:
            ompOnboardingState = .cancelled(subscription)
            return false
        case .failed(let detail):
            ompOnboardingState = .failed(subscription, detail)
            return false
        case .signedIn(let models, let catalogWarning):
            let completed = completeOmpOnboarding(
                subscription,
                models: models,
                catalogWarning: catalogWarning
            )
            if completed {
                _ = await refreshOmpProviderStatuses()
            }
            return completed
        }
    }

    func completeOmpOnboarding(
        _ subscription: OmpSubscription,
        models: [OmpAvailableModel],
        catalogWarning: String?
    ) -> Bool {
        guard settings.refinerProvider == .omp else {
            ompOnboardingState = .signedIn(
                subscription,
                model: nil,
                detail: "Sign-in completed in Oh My Pi. Select Oh My Pi again to use it."
            )
            return false
        }

        let selectedModel = onboardingModel(for: subscription, models: models)
        if let selectedModel, settings.refinerModel != selectedModel {
            settings.refinerModel = selectedModel
            saveSettings()
        }

        let detail = onboardingDetail(
            for: subscription,
            selectedModel: selectedModel,
            catalogWarning: catalogWarning
        )
        ompOnboardingState = .signedIn(subscription, model: selectedModel, detail: detail)
        generations.invalidate(.reachability)
        refinerReachability = onboardingReachability(
            for: subscription,
            selectedModel: selectedModel,
            models: models,
            catalogWarning: catalogWarning
        )
        return true
    }

    func onboardingModel(
        for subscription: OmpSubscription,
        models: [OmpAvailableModel]
    ) -> String? {
        let currentModel = RefinerResolved.model(settings)
        guard let providerID = subscription.providerID else {
            return models.contains(where: { $0.selector == currentModel }) ? currentModel : nil
        }
        if let preferredModel = subscription.preferredModel,
            models.contains(where: { $0.selector == preferredModel })
        {
            return preferredModel
        }
        if models.contains(where: { $0.provider == providerID && $0.selector == currentModel }) {
            return currentModel
        }
        return models.first(where: { $0.provider == providerID })?.selector
    }

    func onboardingDetail(
        for subscription: OmpSubscription,
        selectedModel: String?,
        catalogWarning: String?
    ) -> String {
        var sentences = ["\(subscription.displayName) sign-in completed in Oh My Pi."]
        if let selectedModel {
            sentences.append("Model set to \(selectedModel).")
        } else if subscription.providerID == nil {
            sentences.append("Choose an available provider/model in Model, then run CHECK.")
        } else {
            sentences.append("OMP did not expose a model for this subscription.")
        }
        if let catalogWarning { sentences.append(catalogWarning) }
        return sentences.joined(separator: " ")
    }

    func onboardingReachability(
        for subscription: OmpSubscription,
        selectedModel: String?,
        models: [OmpAvailableModel],
        catalogWarning: String?
    ) -> RefinerReachability {
        if let catalogWarning { return .failed(catalogWarning) }
        guard !models.isEmpty else {
            return .failed("sign-in completed, but OMP exposed no models")
        }
        if subscription.providerID != nil, selectedModel == nil {
            return .failed("sign-in completed, but OMP exposed no \(subscription.displayName) models")
        }
        let effectiveModel = selectedModel ?? RefinerResolved.model(settings)
        guard models.contains(where: { $0.selector == effectiveModel }) else {
            return .failed("selected model unavailable: \(effectiveModel) (\(models.count) models)")
        }
        return .ok(models: models.count)
    }

    @discardableResult
    public func checkRefinerReachability() async -> Bool {
        let probeSettings = settings
        let identity = RefinerIdentity(settings: probeSettings)
        let configurationGeneration = generations.currentToken(.refinerConfiguration)
        let requestGeneration = generations.begin(.reachability)

        guard probeSettings.refinerEnabled else {
            return commitReachability(
                .unknown,
                identity: identity,
                configurationGeneration: configurationGeneration,
                requestGeneration: requestGeneration
            )
        }

        if identity.provider == .omp {
            guard
                commitReachability(
                    .checking,
                    identity: identity,
                    configurationGeneration: configurationGeneration,
                    requestGeneration: requestGeneration
                )
            else {
                return false
            }
            let omp = OmpExecutable.resolve(
                explicitPath: ProcessInfo.processInfo.environment["VOICEOOUR_OMP_BIN"]
            )
            let result = await ompModelsProbe(
                omp.url,
                omp.prefix,
                identity.model,
                max(identity.timeoutMs, 8000)
            )
            return commitReachability(
                result,
                identity: identity,
                configurationGeneration: configurationGeneration,
                requestGeneration: requestGeneration
            )
        }

        if identity.provider == .appleOnDevice {
            let status = FoundationModelsAvailability.summary()
            return commitReachability(
                status.available ? .ok(models: 1) : .failed(status.detail),
                identity: identity,
                configurationGeneration: configurationGeneration,
                requestGeneration: requestGeneration
            )
        }

        guard !identity.endpoint.isEmpty, let url = URL(string: identity.endpoint) else {
            return commitReachability(
                .failed("no base URL"),
                identity: identity,
                configurationGeneration: configurationGeneration,
                requestGeneration: requestGeneration
            )
        }

        guard
            commitReachability(
                .checking,
                identity: identity,
                configurationGeneration: configurationGeneration,
                requestGeneration: requestGeneration
            )
        else {
            return false
        }
        let apiKey = refinerAPIKeyProvider(identity.provider, identity.endpoint)
        let selectedModel = identity.provider == .custom ? nil : identity.model
        let result = await cloudReachabilityProbe(
            url,
            apiKey,
            selectedModel,
            identity.timeoutMs
        )
        return commitReachability(
            result,
            identity: identity,
            configurationGeneration: configurationGeneration,
            requestGeneration: requestGeneration
        )
    }
}
