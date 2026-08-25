import AVFoundation
import Foundation
import VoiceCore

/// Everything a backend needs to build itself.
public struct ASRBackendContext: Sendable {
    /// The `voiceour-asr` helper this process should spawn. Always a sibling of the running
    /// executable: SwiftPM's products directory and an app bundle's `Contents/MacOS` are both
    /// flat, so one rule covers `swift run`, the benchmark and the shipped bundle.
    public let sidecarExecutableURL: URL
    /// Which artifact of the pinned repository this launch should load. Held here rather than
    /// on the descriptor because it is the user's current selection, not a property of the
    /// backend: the descriptor set is compiled, the selection changes.
    public let modelVariant: ASRModelVariant

    public init(sidecarExecutableURL: URL, modelVariant: ASRModelVariant = .default) {
        self.sidecarExecutableURL = sidecarExecutableURL
        self.modelVariant = modelVariant
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
/// AVFoundation capture recorders and a process-launching sidecar client, neither
/// of which VoiceCore may import.
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

    /// The backend used when no id resolves: the real local sidecar. It is the
    /// fallback for a stale or unknown `settings.asrBackend` too, so a value from a
    /// future build degrades to real dictation rather than to synthetic text.
    public var defaultDescriptor: ASRBackendDescriptor {
        descriptor(for: Self.parakeetBackendID) ?? descriptors[0]
    }

    public func descriptor(for id: String) -> ASRBackendDescriptor? {
        descriptors.first { $0.id == id }
    }

    /// An unregistered id falls back to `defaultDescriptor`. It never traps: a stale
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
            modelId: ASRModelContract.modelId,
            modelRevision: ASRModelContract.revision,
            makeComponents: { context in
                ASRBackendComponents(
                    recorder: MicrophoneRecorder(),
                    client: SidecarASRClient(
                        sidecarExecutableURL: context.sidecarExecutableURL,
                        backend: Self.parakeetBackendID,
                        modelVariant: context.modelVariant,
                        expectedModel: Self.parakeetModel(context.modelVariant)
                    ),
                    usesSystemAudioMuter: true
                )
            }
        ),
    ])

    /// The model the sidecar must have loaded, echoed on every transcribe.
    ///
    /// The artifact is part of it because the pinned repository holds several: without `file`
    /// a sidecar still serving the previously selected variant would pass the check.
    private static func parakeetModel(_ variant: ASRModelVariant) -> ASRExpectedModel {
        ASRExpectedModel(
            modelId: ASRModelContract.modelId,
            revision: ASRModelContract.revision,
            file: variant.fileName
        )
    }
}
