import AVFoundation
import Foundation
import VoiceCore

#if canImport(Speech)
    import Speech
#endif

/// Everything a backend needs to build itself.
public struct ASRBackendContext: Sendable {
    public let asrDirectory: URL
    public let speechLocale: String

    public init(asrDirectory: URL, speechLocale: String) {
        self.asrDirectory = asrDirectory
        self.speechLocale = speechLocale
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
    public let makeLive: @Sendable (ASRBackendContext) -> ASRBackendComponents
    public let makeClient: @Sendable (ASRBackendContext) -> any ASRClienting

    public init(
        id: String,
        displayName: String,
        modelLabel: String,
        makeLive: @escaping @Sendable (ASRBackendContext) -> ASRBackendComponents,
        makeClient: @escaping @Sendable (ASRBackendContext) -> any ASRClienting
    ) {
        self.id = id
        self.displayName = displayName
        self.modelLabel = modelLabel
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
        descriptor(for: "fake") ?? descriptors[0]
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
            id: "fake",
            displayName: "FAKE",
            modelLabel: "no model · synthetic transcripts",
            makeLive: { context in
                ASRBackendComponents(
                    recorder: FakeAudioRecorder(),
                    client: SidecarASRClient(asrDirectory: context.asrDirectory, backend: "fake"),
                    usesSystemAudioMuter: false
                )
            },
            makeClient: { context in
                SidecarASRClient(asrDirectory: context.asrDirectory, backend: "fake")
            }
        ),
        ASRBackendDescriptor(
            id: "mlx",
            displayName: "PARAKEET MLX",
            modelLabel: ASRModelContract.modelId,
            makeLive: { context in
                ASRBackendComponents(
                    recorder: AVAudioEngineRecorder(),
                    client: SidecarASRClient(asrDirectory: context.asrDirectory, backend: "mlx"),
                    usesSystemAudioMuter: true
                )
            },
            makeClient: { context in
                SidecarASRClient(asrDirectory: context.asrDirectory, backend: "mlx")
            }
        ),
        ASRBackendDescriptor(
            id: "apple",
            displayName: "APPLE SPEECH",
            modelLabel: "apple/SpeechTranscriber (system-managed)",
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
                    recorder: AVAudioEngineRecorder(),
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
}
