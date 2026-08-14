import Foundation
import VoiceCore

/// One refiner provider: its metadata and how to construct its backend.
public struct RefinerProviderDescriptor: Sendable {
    public let id: RefinerProvider
    public let displayName: String
    public let defaultModel: String
    public let make: @Sendable (Settings) -> any TranscriptRefining

    public init(
        id: RefinerProvider,
        displayName: String,
        defaultModel: String,
        make: @escaping @Sendable (Settings) -> any TranscriptRefining
    ) {
        self.id = id
        self.displayName = displayName
        self.defaultModel = defaultModel
        self.make = make
    }
}

/// Runtime dispatch from a `RefinerProvider` to the backend that serves it.
///
/// Adding a provider used to touch eleven files, and vendor types leaked from
/// VoiceMac into VoiceCore, the coordinator, three UI files, the harness
/// fixtures and the benchmark. Construction happens in one place.
///
/// `RefinerProvider` stays a closed `Codable` enum whose raw values are the
/// `refiner_provider` key in `settings.json`. This registry is runtime dispatch
/// only and never encodes an id into settings, so it cannot change the stored
/// format.
public struct RefinerProviderRegistry: Sendable {
    private let descriptorsByID: [RefinerProvider: RefinerProviderDescriptor]

    public init(descriptors: [RefinerProviderDescriptor]) {
        descriptorsByID = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, $0) })
    }

    public var descriptors: [RefinerProviderDescriptor] {
        RefinerProvider.allCases.compactMap { descriptorsByID[$0] }
    }

    public func descriptor(for provider: RefinerProvider) -> RefinerProviderDescriptor? {
        descriptorsByID[provider]
    }

    /// Builds the backend for `settings.refinerProvider`. An unregistered
    /// provider yields an `UnsupportedRefiner` rather than trapping, matching how
    /// every other unavailable backend reports itself.
    public func make(settings: Settings) -> any TranscriptRefining {
        guard let descriptor = descriptorsByID[settings.refinerProvider] else {
            return UnsupportedRefiner(reason: "unconfigured")
        }
        return descriptor.make(settings)
    }

    /// The shipped provider set.
    ///
    /// Metadata is read from `RefinerProvider` itself rather than restated, so
    /// the enum stays the single source for display names and default models
    /// and the two cannot drift.
    public static func live(
        environment: [String: String],
        deterministicFallback: @escaping @Sendable (String) -> String
    ) -> RefinerProviderRegistry {
        RefinerProviderRegistry(
            descriptors: RefinerProvider.allCases.map { provider in
                RefinerProviderDescriptor(
                    id: provider,
                    displayName: provider.displayName,
                    defaultModel: provider.defaultModel,
                    make: { settings in
                        Self.makeBackend(
                            provider: provider,
                            settings: settings,
                            environment: environment,
                            deterministicFallback: deterministicFallback
                        )
                    }
                )
            })
    }

    private static func makeBackend(
        provider: RefinerProvider,
        settings: Settings,
        environment: [String: String],
        deterministicFallback: @escaping @Sendable (String) -> String
    ) -> any TranscriptRefining {
        switch provider {
        case .omp:
            let omp = OmpExecutable.resolve(explicitPath: environment["VOICEOUR_OMP_BIN"])
            return OmpRpcRefiner(
                configuration: OmpRpcRefinerConfiguration(
                    enabled: settings.refinerEnabled,
                    executableURL: omp.url,
                    argumentPrefix: omp.prefix,
                    model: RefinerResolved.model(settings),
                    timeoutMs: max(settings.refinerTimeoutMs, 1_000),
                    profileDirectory: OmpRpcProfile.defaultDirectory()
                ),
                deterministicFallback: deterministicFallback
            )
        case .appleOnDevice:
            #if canImport(FoundationModels)
                if #available(macOS 26.0, *) {
                    return FoundationModelsRefiner(
                        configuration: FoundationModelsRefinerConfiguration(
                            enabled: settings.refinerEnabled,
                            timeoutMs: max(settings.refinerTimeoutMs, 1_000)
                        ),
                        deterministicFallback: deterministicFallback
                    )
                }
                return UnsupportedRefiner(reason: "requires_macos_26")
            #else
                return UnsupportedRefiner(reason: "requires_macos_26")
            #endif
        }
    }
}
