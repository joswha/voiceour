import AVFoundation
import Foundation
import VoiceCore

#if canImport(Speech)
    import Speech
#endif

/// Everything a backend needs to build itself.
public struct ASRBackendContext: Sendable {
    /// The `voiceour-asr` helper this process should spawn. Always a sibling of the running
    /// executable: SwiftPM's products directory and an app bundle's `Contents/MacOS` are both
    /// flat, so one rule covers `swift run`, the benchmark and the shipped bundle.
    public let sidecarExecutableURL: URL
    public let speechLocale: String

    public init(sidecarExecutableURL: URL, speechLocale: String) {
        self.sidecarExecutableURL = sidecarExecutableURL
        self.speechLocale = speechLocale
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
///
/// `makeLive` and `makeClient` are deliberately separate. The live Apple backend
/// is the fused `AppleSpeechDictationEngine`, which records and transcribes at
/// once; the benchmark needs the batch `AppleSpeechASRClient` instead. Collapsing
/// them into one factory would silently change what the benchmark measures.
public struct ASRBackendDescriptor: Sendable {
    public let id: String
    public let displayName: String
    public let modelLabel: String
    /// The real model behind the backend, as opposed to `modelLabel`, which is
    /// a display string ("no model · synthetic transcripts") that no consumer
    /// can act on. Benchmark metadata, Diagnostics and the sidecar's
    /// `expected_model` all need the identity itself. Nil where the backend
    /// loads no model of its own; `modelRevision` is additionally nil where
    /// nothing pins one, as with Apple's system-managed transcriber.
    public let modelId: String?
    public let modelRevision: String?
    public let makeLive: @Sendable (ASRBackendContext) -> ASRBackendComponents
    public let makeClient: @Sendable (ASRBackendContext) -> any ASRClienting

    public init(
        id: String,
        displayName: String,
        modelLabel: String,
        modelId: String?,
        modelRevision: String?,
        makeLive: @escaping @Sendable (ASRBackendContext) -> ASRBackendComponents,
        makeClient: @escaping @Sendable (ASRBackendContext) -> any ASRClienting
    ) {
        self.id = id
        self.displayName = displayName
        self.modelLabel = modelLabel
        self.modelId = modelId
        self.modelRevision = modelRevision
        self.makeLive = makeLive
        self.makeClient = makeClient
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
    private static let appleBackendID = "apple"

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
        (descriptor(for: id) ?? defaultDescriptor).makeLive(context)
    }

    public func client(for id: String, context: ASRBackendContext) -> any ASRClienting {
        (descriptor(for: id) ?? defaultDescriptor).makeClient(context)
    }

    public static let builtIn = ASRBackendRegistry(descriptors: [
        ASRBackendDescriptor(
            id: Self.fakeBackendID,
            displayName: "FAKE",
            modelLabel: "no model · synthetic transcripts",
            modelId: nil,
            modelRevision: nil,
            makeLive: { context in
                ASRBackendComponents(
                    recorder: FakeAudioRecorder(),
                    client: SidecarASRClient(
                        sidecarExecutableURL: context.sidecarExecutableURL,
                        backend: Self.fakeBackendID
                    ),
                    usesSystemAudioMuter: false
                )
            },
            makeClient: { context in
                SidecarASRClient(
                    sidecarExecutableURL: context.sidecarExecutableURL,
                    backend: Self.fakeBackendID
                )
            }
        ),
        ASRBackendDescriptor(
            id: Self.parakeetBackendID,
            displayName: "PARAKEET",
            modelLabel: ASRModelContract.modelId,
            modelId: Self.parakeetModel.modelId,
            modelRevision: Self.parakeetModel.revision,
            makeLive: { context in
                ASRBackendComponents(
                    recorder: MicrophoneRecorder(),
                    client: SidecarASRClient(
                        sidecarExecutableURL: context.sidecarExecutableURL,
                        backend: Self.parakeetBackendID,
                        expectedModel: Self.parakeetModel
                    ),
                    usesSystemAudioMuter: true
                )
            },
            makeClient: { context in
                SidecarASRClient(
                    sidecarExecutableURL: context.sidecarExecutableURL,
                    backend: Self.parakeetBackendID,
                    expectedModel: Self.parakeetModel
                )
            }
        ),
        ASRBackendDescriptor(
            id: Self.appleBackendID,
            displayName: "APPLE SPEECH",
            modelLabel: "apple/SpeechTranscriber (system-managed)",
            modelId: "apple/SpeechTranscriber",
            // The transcriber ships with the OS and pins nothing of its own;
            // callers that need a revision substitute the OS version.
            modelRevision: nil,
            makeLive: { context in
                // The availability gate lives only here. It used to be duplicated
                // in the coordinator's live() and in BenchMain.
                #if canImport(Speech)
                    if #available(macOS 26.0, *) {
                        // One fused engine records AND streams transcription, so the
                        // dictation is mostly transcribed by the time the hotkey
                        // stops it.
                        let engine = AppleSpeechDictationEngine(locale: Locale(identifier: context.speechLocale))
                        return ASRBackendComponents(recorder: engine, client: engine, usesSystemAudioMuter: true)
                    }
                #endif
                return ASRBackendComponents(
                    recorder: MicrophoneRecorder(),
                    client: Self.unsupportedAppleSpeech,
                    usesSystemAudioMuter: true
                )
            },
            makeClient: { _ in
                #if canImport(Speech)
                    if #available(macOS 26.0, *) {
                        return AppleSpeechASRClient()
                    }
                #endif
                return Self.unsupportedAppleSpeech
            }
        ),
    ])

    private static var unsupportedAppleSpeech: UnsupportedASRClient {
        UnsupportedASRClient(backendId: "apple-speech", detail: "Apple Speech backend requires macOS 26")
    }

    /// The model each sidecar backend must have loaded, which is also the
    /// identity its descriptor publishes: one place per backend where an id and
    /// its pinned revision are written, rather than four.
    private static let parakeetModel = ASRExpectedModel(
        modelId: ASRModelContract.modelId,
        revision: ASRModelContract.revision
    )
}
