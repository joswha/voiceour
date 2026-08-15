import AVFoundation
import Foundation
import VoiceCore

/// Everything a backend needs to build itself.
public struct ASRBackendContext: Sendable {
    /// The `voiceour-asr` helper this process should spawn. Always a sibling of the running
    /// executable: SwiftPM's products directory and an app bundle's `Contents/MacOS` are both
    /// flat, so one rule covers `swift run`, the benchmark and the shipped bundle.
    public let sidecarExecutableURL: URL

    public init(sidecarExecutableURL: URL) {
        self.sidecarExecutableURL = sidecarExecutableURL
    }

    /// The sibling lookup itself, so every caller resolves it identically.
    public static func siblingSidecarURL(
        of executableURL: URL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    ) -> URL {
        executableURL.deletingLastPathComponent().appendingPathComponent("voiceour-asr")
    }
}

/// The pieces a live dictation session needs from a backend.
public struct ASRBackendComponents: Sendable {
    public let recorder: any AudioRecording
    public let client: any ASRClienting
    /// False only for the fake backend, which produces synthetic audio and has
    /// no speaker output worth muting.
    public let usesSystemAudioMuter: Bool

    public init(recorder: any AudioRecording, client: any ASRClienting, usesSystemAudioMuter: Bool) {
        self.recorder = recorder
        self.client = client
        self.usesSystemAudioMuter = usesSystemAudioMuter
    }
}

/// One ASR backend: its stable id, how it presents itself, and how to build it.
public struct ASRBackendDescriptor: Sendable {
    public let id: String
    public let displayName: String
    public let modelLabel: String
    /// The real model behind the backend, as opposed to `modelLabel`, which is
    /// a display string ("no model · synthetic transcripts") that no consumer
    /// can act on. Benchmark metadata, Diagnostics and the sidecar's
    /// `expected_model` all need the identity itself. Both are nil where the
    /// backend loads no model of its own.
    public let modelId: String?
    public let modelRevision: String?
    public let makeComponents: @Sendable (ASRBackendContext) -> ASRBackendComponents

    public init(
        id: String,
        displayName: String,
        modelLabel: String,
        modelId: String?,
        modelRevision: String?,
        makeComponents: @escaping @Sendable (ASRBackendContext) -> ASRBackendComponents
    ) {
        self.id = id
        self.displayName = displayName
        self.modelLabel = modelLabel
        self.modelId = modelId
        self.modelRevision = modelRevision
        self.makeComponents = makeComponents
    }
}

/// The set of ASR backends the app knows how to build.
///
/// Adding a backend used to mean editing ten files: the coordinator's live
/// wiring, the recorder and muter choice, the launch-option validator, the Voice
/// pane's picker, the model-label helper, and the benchmark's parser, factory and
/// metadata. Registering one descriptor now covers all of them.
///
/// It lives in VoiceMac rather than VoiceCore because the factories construct
/// AVFoundation and Speech adapters, which VoiceCore may not import.
public struct ASRBackendRegistry: Sendable {
    public let descriptors: [ASRBackendDescriptor]
    private static let fakeBackendID = "fake"
    private static let parakeetBackendID = "parakeet"

    public init(descriptors: [ASRBackendDescriptor]) {
        self.descriptors = descriptors
    }

    public var backendIDs: Set<String> {
        Set(descriptors.map(\.id))
    }

    /// The fake backend: no model download, no microphone, deterministic
    /// transcripts. It is the default because it is the only backend that works
    /// on a machine that has never run this app.
    public var defaultDescriptor: ASRBackendDescriptor {
        descriptor(for: Self.fakeBackendID) ?? descriptors[0]
    }

    public func descriptor(for id: String) -> ASRBackendDescriptor? {
        descriptors.first { $0.id == id }
    }

    /// An unregistered id falls back to `defaultDescriptor`, matching the
    /// `?? "fake"` the coordinator applied before. It never traps: a stale
    /// `settings.asrBackend` from a future build must not crash the app.
    public func liveComponents(for id: String, context: ASRBackendContext) -> ASRBackendComponents {
        (descriptor(for: id) ?? defaultDescriptor).makeComponents(context)
    }

    /// The client alone, for the benchmark: it transcribes files and never records.
    public func client(for id: String, context: ASRBackendContext) -> any ASRClienting {
        liveComponents(for: id, context: context).client
    }

    public static let builtIn = ASRBackendRegistry(descriptors: [
        ASRBackendDescriptor(
            id: Self.fakeBackendID,
            displayName: "FAKE",
            modelLabel: "no model · synthetic transcripts",
            modelId: nil,
            modelRevision: nil,
            makeComponents: { context in
                ASRBackendComponents(
                    recorder: FakeAudioRecorder(),
                    client: SidecarASRClient(
                        sidecarExecutableURL: context.sidecarExecutableURL,
                        backend: Self.fakeBackendID
                    ),
                    usesSystemAudioMuter: false
                )
            }
        ),
        ASRBackendDescriptor(
            id: Self.parakeetBackendID,
            displayName: "PARAKEET",
            modelLabel: ASRModelContract.modelId,
            modelId: Self.parakeetModel.modelId,
            modelRevision: Self.parakeetModel.revision,
            makeComponents: { context in
                ASRBackendComponents(
                    recorder: MicrophoneRecorder(),
                    client: SidecarASRClient(
                        sidecarExecutableURL: context.sidecarExecutableURL,
                        backend: Self.parakeetBackendID,
                        expectedModel: Self.parakeetModel
                    ),
                    usesSystemAudioMuter: true
                )
            }
        ),
    ])

    /// The model each sidecar backend must have loaded, which is also the
    /// identity its descriptor publishes: one place per backend where an id and
    /// its pinned revision are written, rather than four.
    private static let parakeetModel = ASRExpectedModel(
        modelId: ASRModelContract.modelId,
        revision: ASRModelContract.revision
    )
}
