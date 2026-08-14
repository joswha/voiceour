/// Every refinement destination Voiceour offers.
///
/// There are exactly two, and the axis is where the text goes, not who trained
/// the model: `omp` hands the request to the locally installed Oh My Pi CLI,
/// which owns the provider credentials and brokers whichever subscription the
/// user signed into; `appleOnDevice` never leaves the Mac.
///
/// There is deliberately no third case for talking to a model vendor directly.
/// OMP already reaches all of them without this app holding a credential, so
/// Voiceour has no API-key field, no keychain item and no per-provider base
/// URL. Adding one back would put a secret in a bundle that cannot use the
/// data protection keychain; `docs/architecture.md` records that measurement.
public enum RefinerProvider: String, Codable, Equatable, Sendable, CaseIterable {
    case omp
    case appleOnDevice

    public var displayName: String {
        switch self {
        case .omp: "Oh My Pi"
        case .appleOnDevice: "Apple On-Device"
        }
    }

    /// The model used when the user has not picked one.
    ///
    /// OMP's real list is inherited at runtime from `omp models`, which needs a
    /// subprocess and therefore cannot be reached from this Foundation-only
    /// resolver. This constant is only the pre-selection default: it names a
    /// cheap, fast model, and the Model picker replaces it with a real
    /// selection from OMP's catalog. Apple's on-device model is the only model
    /// its provider has, so its id is a label rather than a choice.
    public var defaultModel: String {
        switch self {
        case .omp: "anthropic/claude-haiku-4-5"
        case .appleOnDevice: "on-device"
        }
    }
}

public enum RefinerResolved: Sendable {
    /// The model the refiner will actually use.
    ///
    /// `Settings.refinerModel` belongs to OMP: it is a `provider/model` selector
    /// picked out of OMP's catalog. Apple's provider has exactly one model, so
    /// it resolves to that model whatever the field holds — which is what lets
    /// the field keep an OMP choice while the user is temporarily on the
    /// on-device model, instead of the round trip erasing it.
    public static func model(_ settings: Settings) -> String {
        switch settings.refinerProvider {
        case .appleOnDevice:
            return settings.refinerProvider.defaultModel
        case .omp:
            return settings.refinerModel.isEmpty ? settings.refinerProvider.defaultModel : settings.refinerModel
        }
    }
}

public enum RefinerReadiness: Equatable, Sendable {
    case disabled, needsModel, ready

    public var label: String {
        switch self {
        case .disabled: "OFF"
        case .needsModel: "NEEDS MODEL"
        case .ready: "READY"
        }
    }

    public var isReady: Bool { self == .ready }

    /// Neither provider takes a credential from Voiceour: OMP holds its own,
    /// and the on-device model needs none. So readiness is only ever "is it on"
    /// and "does it have a model", and the on-device provider always has one.
    public static func evaluate(settings: Settings) -> RefinerReadiness {
        guard settings.refinerEnabled else { return .disabled }
        switch settings.refinerProvider {
        case .omp:
            return RefinerResolved.model(settings).isEmpty ? .needsModel : .ready
        case .appleOnDevice:
            // The system model needs no endpoint, key, or model choice; runtime
            // availability (Apple Intelligence state) is checked by the refiner.
            return .ready
        }
    }
}

/// How the configured refiner answered when last asked.
///
/// There is no `unauthorized`: neither provider takes a credential from
/// Voiceour, so nothing can reject one. OMP owns its own tokens and reports a
/// broken one as an ordinary failure reason.
public enum RefinerReachability: Equatable, Sendable {
    case unknown, checking
    case ok(models: Int)
    case failed(String)
}
