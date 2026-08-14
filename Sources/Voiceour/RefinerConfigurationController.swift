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
        let model: String
        let timeoutMs: Int

        init(settings: VoiceCore.Settings) {
            enabled = settings.refinerEnabled
            provider = settings.refinerProvider
            model = RefinerResolved.model(settings)
            timeoutMs = settings.refinerTimeoutMs
        }

        var label: String {
            "\(provider.rawValue):\(model)"
        }

        /// Whether this configuration sends the transcript off the Mac. OMP
        /// brokers to a network provider; Apple's model does not.
        var isCloud: Bool {
            provider != .appleOnDevice
        }
    }

    struct RefinerBinding {
        let backend: TranscriptRefining
        let identity: RefinerIdentity
        let configurationGeneration: AsyncGenerationGate.Token
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

    /// Promotes a durable refine failure into the Status row's verdict.
    ///
    /// Only durable ones. A refine reports why it fell back, and most reasons
    /// describe the utterance rather than the configuration — a timeout on a
    /// long transcript, a superseded request, a guard rejection. Those say
    /// nothing about whether the refiner works. The reasons below say OMP could
    /// not run at all, which is exactly the answer the user would otherwise
    /// have to press CHECK to discover, after a paste already silently fell
    /// back to deterministic cleanup.
    func applyRefinerReachabilityFailureIfCurrent(
        _ reason: String,
        binding: RefinerBinding
    ) {
        guard binding.identity.isCloud,
            generations.isCurrent(binding.configurationGeneration),
            binding.identity == RefinerIdentity(settings: settings),
            Self.durableRefinerFailurePrefixes.contains(where: reason.hasPrefix)
        else {
            return
        }
        generations.invalidate(.reachability)
        refinerReachability = .failed(reason)
    }

    /// The `OmpRpcError.shortMessage` prefixes that describe a broken refiner
    /// rather than a difficult request.
    static let durableRefinerFailurePrefixes = [
        "launch failed:",
        "omp not ready:",
        "omp exited:",
        "omp protocol error:",
    ]

    public func selectRefinerProvider(_ provider: RefinerProvider) {
        guard settings.refinerProvider != provider else { return }
        settings.refinerProvider = provider
        // `refinerModel` is deliberately left alone. It is OMP's selector, and
        // `RefinerResolved.model` already ignores it on the on-device provider,
        // so switching over to look at Apple's row and back keeps the model the
        // user picked instead of silently resetting it to the default.
        saveSettings()
    }

    /// Records the model the user picked from OMP's own catalog. An empty
    /// selector restores the provider default rather than leaving the refiner
    /// with no model at all.
    public func selectRefinerModel(_ selector: String) {
        let trimmed = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.refinerModel != trimmed else { return }
        settings.refinerModel = trimmed
        saveSettings()
    }

    /// Loads the model list Voiceour offers in the Model picker straight from
    /// `omp models --json`, so the choices are whatever the user's own OMP
    /// installation can actually reach rather than a list this app maintains
    /// and lets drift.
    @discardableResult
    public func refreshOmpModelCatalog(timeoutMs: Int = 30_000) async -> Bool {
        let requestGeneration = generations.begin(.modelCatalog)
        ompModelCatalogState = .loading
        let environment = ProcessInfo.processInfo.environment
        let omp = OmpExecutable.resolve(explicitPath: environment["VOICEOUR_OMP_BIN"])

        do {
            let models = try await ompModelCatalogLoad(omp.url, omp.prefix, max(timeoutMs, 1))
            guard generations.isCurrent(requestGeneration) else { return false }
            ompModels = models.sorted { left, right in
                left.provider == right.provider
                    ? left.selector.localizedCaseInsensitiveCompare(right.selector) == .orderedAscending
                    : left.provider.localizedCaseInsensitiveCompare(right.provider) == .orderedAscending
            }
            ompModelCatalogState = .loaded
            return true
        } catch is CancellationError {
            guard generations.isCurrent(requestGeneration) else { return false }
            ompModelCatalogState = .idle
            return false
        } catch {
            guard generations.isCurrent(requestGeneration) else { return false }
            let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            ompModelCatalogState = .failed(detail)
            return false
        }
    }

    /// Refreshes the redacted provider/account inventory that `omp usage`
    /// exposes. The probe returns counts only; OAuth credentials stay inside OMP.
    @discardableResult
    public func refreshOmpProviderStatuses(timeoutMs: Int = 30_000) async -> Bool {
        let requestGeneration = generations.begin(.providerStatus)
        let previousState = ompProviderStatusState
        ompProviderStatusState = .checking
        let environment = ProcessInfo.processInfo.environment
        let omp = OmpExecutable.resolve(explicitPath: environment["VOICEOUR_OMP_BIN"])

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

        switch identity.provider {
        case .omp:
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
                explicitPath: ProcessInfo.processInfo.environment["VOICEOUR_OMP_BIN"]
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

        case .appleOnDevice:
            let status = FoundationModelsAvailability.summary()
            return commitReachability(
                status.available ? .ok(models: 1) : .failed(status.detail),
                identity: identity,
                configurationGeneration: configurationGeneration,
                requestGeneration: requestGeneration
            )
        }
    }
}
