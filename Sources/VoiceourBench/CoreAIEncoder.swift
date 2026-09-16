import ASRSidecarCore
import CoreAI
import Dispatch
import Foundation

/// Benchmark-only fixed 15 s encoder, sharing the CoreML tier's IO contract.
/// Compiled into `voiceour-bench`, never the shipping helper.
struct CoreAIEncoderConfiguration: Sendable {
    /// The compute units a specialization may prefer. The raw values are the
    /// `voiceour-bench --coreai-compute` spellings.
    enum ComputeUnits: String, CaseIterable, Sendable {
        case `default`
        case neuralEngine = "neural-engine"
        case cpu
    }

    /// Whether the specialized model is cached, and how long the cache entry survives. The raw
    /// values are the `voiceour-bench --coreai-cache` spellings.
    enum CachePolicy: String, CaseIterable, Sendable {
        case none
        case `default`
        case persistent
    }

    static let melBins = ParakeetContext.NativeMel.melBins
    static let encoderChannels = ParakeetContext.encoderStateWidth
    static let melFrameCapacity = 1_501
    static let encoderFrameCapacity = 188
    static let maximumSampleCount = 240_000
    /// The FastConformer's subsampling: `encoder_length == ceil(mel frames / 8)`, the same
    /// relation the tail checks in `transcribeWithExternalStates`.
    static let melSubsamplingFactor = 8
    static let functionName = "main"
    static let melInputName = "mel"
    static let melLengthInputName = "mel_length"
    static let encoderOutputName = "encoder"
    static let encoderLengthOutputName = "encoder_length"

    let modelURL: URL
    let computeUnits: ComputeUnits
    let cachePolicy: CachePolicy

    init(
        modelURL: URL,
        computeUnits: ComputeUnits = .default,
        cachePolicy: CachePolicy = .default
    ) {
        self.modelURL = modelURL
        self.computeUnits = computeUnits
        self.cachePolicy = cachePolicy
    }
}

/// What one `CoreAIEncoder.load` cost and where it ran, for the experiment's `encoder_meta` row.
struct CoreAIEncoderLoad: Sendable {
    let specializationMs: Int
    let loadFunctionMs: Int
    let deviceArchitecture: String
    let availableComputeUnits: [String]
}

enum CoreAIEncoderError: Error, CustomStringConvertible {
    case modelMissing(String)
    case unsupportedModelPath(String)
    case invalidModelAsset(String)
    case modelLoadFailed(path: String, detail: String)
    case functionMissing(path: String, available: [String])
    case modelContract(String)
    case nativeMelContract(String)
    case inputTooLong(frameCount: Int, capacity: Int)
    case predictionContract(String)
    case frameCountMismatch(reported: Int, expected: Int)
    case nonFiniteState(frame: Int, channel: Int)

    var description: String {
        switch self {
        case .modelMissing(let path):
            return "Core AI encoder does not exist at \(path)"
        case .unsupportedModelPath(let path):
            return "Core AI encoder must be a .aimodel or .aimodelc: \(path)"
        case .invalidModelAsset(let path):
            return "Core AI encoder is not a valid model asset: \(path)"
        case .modelLoadFailed(let path, let detail):
            return "Core AI encoder load failed for \(path): \(detail)"
        case .functionMissing(let path, let available):
            return
                "Core AI encoder at \(path) has no \(CoreAIEncoderConfiguration.functionName) function; it declares \(available)"
        case .modelContract(let detail):
            return "Core AI encoder model contract failed: \(detail)"
        case .nativeMelContract(let detail):
            return "native mel contract failed: \(detail)"
        case .inputTooLong(let frameCount, let capacity):
            return "\(frameCount) mel frames exceed the fixed \(capacity)-frame window"
        case .predictionContract(let detail):
            return "Core AI encoder prediction contract failed: \(detail)"
        case .frameCountMismatch(let reported, let expected):
            return
                "\(CoreAIEncoderConfiguration.encoderLengthOutputName) \(reported) does not equal subsampled mel length \(expected)"
        case .nonFiniteState(let frame, let channel):
            return "Core AI encoder state at frame \(frame), channel \(channel) is not finite"
        }
    }
}

/// One non-Sendable owner reuses the model, function and input buffers across awaited encodes.
/// Outputs are copied into the frame-major layout the ggml tail consumes.
final class CoreAIEncoder {
    /// Frame-major `[frames, 1024]` encoder states, the exact layout and width
    /// `ParakeetContext.transcribeWithExternalStates` expects.
    struct EncodedStates: Sendable {
        let frameCount: Int
        let values: [Float]
    }

    private typealias Contract = CoreAIEncoderConfiguration

    /// The specialized model owns the storage the function runs in; it is held for that lifetime.
    private let model: AIModel
    private let function: InferenceFunction
    private var melInput: NDArray
    private var melLengthInput: NDArray

    /// Specializes the artifact, validates its declared signature, then obtains `main`.
    ///
    /// Specialization and function load are timed separately: the first is the cost a warm
    /// `AIModelCache` removes, the second is what every process pays.
    static func load(
        configuration: CoreAIEncoderConfiguration
    ) async throws -> (CoreAIEncoder, CoreAIEncoderLoad) {
        try validateArtifact(configuration: configuration)
        let path = configuration.modelURL.path
        let options = specializationOptions(for: configuration.computeUnits)

        let specializationStart = DispatchTime.now()
        let model: AIModel
        do {
            switch configuration.cachePolicy {
            case .none:
                model = try await AIModel(contentsOf: configuration.modelURL, options: options)
            case .default:
                model = try await AIModel.specialize(
                    contentsOf: configuration.modelURL,
                    options: options,
                    cache: .default,
                    cachePolicy: .default
                )
            case .persistent:
                model = try await AIModel.specialize(
                    contentsOf: configuration.modelURL,
                    options: options,
                    cache: .default,
                    cachePolicy: .persistent
                )
            }
        } catch {
            throw CoreAIEncoderError.modelLoadFailed(path: path, detail: String(describing: error))
        }
        let specializationMs = milliseconds(since: specializationStart)

        try validate(model: model, path: path)

        let loadStart = DispatchTime.now()
        let loaded: InferenceFunction?
        do {
            loaded = try model.loadFunction(named: Contract.functionName)
        } catch {
            throw CoreAIEncoderError.modelLoadFailed(path: path, detail: String(describing: error))
        }
        let loadFunctionMs = milliseconds(since: loadStart)
        guard let function = loaded else {
            throw CoreAIEncoderError.functionMissing(path: path, available: model.functionNames)
        }

        let encoder = CoreAIEncoder(model: model, function: function)
        let load = CoreAIEncoderLoad(
            specializationMs: specializationMs,
            loadFunctionMs: loadFunctionMs,
            deviceArchitecture: AIModel.deviceArchitectureName,
            availableComputeUnits: ComputeUnitKind.availableKinds.map { name(of: $0) }.sorted()
        )
        return (encoder, load)
    }

    /// Refuses a missing path, a path that is not a Core AI artifact, and an `.aimodel` the
    /// runtime itself rejects — each named by its path, before any specialization work.
    private static func validateArtifact(configuration: CoreAIEncoderConfiguration) throws {
        let path = configuration.modelURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            throw CoreAIEncoderError.modelMissing(path)
        }
        switch configuration.modelURL.pathExtension.lowercased() {
        case "aimodel":
            guard AIModelAsset.isValid(at: configuration.modelURL) else {
                throw CoreAIEncoderError.invalidModelAsset(path)
            }
        case "aimodelc":
            // An ahead-of-time compiled artifact carries no asset manifest; the runtime
            // validates it during specialization.
            break
        default:
            throw CoreAIEncoderError.unsupportedModelPath(path)
        }
    }

    private init(model: AIModel, function: InferenceFunction) {
        self.model = model
        self.function = function
        self.melInput = NDArray(
            shape: [1, Contract.melBins, Contract.melFrameCapacity],
            scalarType: .float32
        )
        self.melLengthInput = NDArray(shape: [1], scalarType: .int32)
    }

    /// Transposes `mel` into the reusable fixed input, runs the function, and copies the valid
    /// encoder frames into freshly owned frame-major storage.
    func encode(_ mel: ParakeetContext.NativeMel) async throws -> EncodedStates {
        let bins = Contract.melBins
        let capacity = Contract.melFrameCapacity
        let frames = mel.frameCount
        guard frames <= capacity else {
            throw CoreAIEncoderError.inputTooLong(frameCount: frames, capacity: capacity)
        }
        guard frames > 0, mel.values.count == frames * bins else {
            throw CoreAIEncoderError.nativeMelContract(
                "expected [frames,\(bins)] with 1...\(capacity) frames; got \(mel.values.count) values over \(frames) frames"
            )
        }

        Self.write(mel, into: &melInput)
        Self.write(frameCount: frames, into: &melLengthInput)

        var outputs = try await function.run(
            inputs: [Contract.melInputName: melInput, Contract.melLengthInputName: melLengthInput]
        )
        guard outputs.count == 2 else {
            throw CoreAIEncoderError.predictionContract("expected 2 outputs; got \(outputs.count)")
        }

        let frameCount = try Self.encoderFrameCount(from: &outputs, melFrameCount: frames)
        let values = try Self.states(from: &outputs, frameCount: frameCount)
        return EncodedStates(frameCount: frameCount, values: values)
    }

    // MARK: - Inputs

    /// Writes frame-major mel into the reusable channel-major input. The typed
    /// view supplies element strides, including any padding in its backing store.
    private static func write(_ mel: ParakeetContext.NativeMel, into input: inout NDArray) {
        let frames = mel.frameCount
        let bins = Contract.melBins
        let capacity = Contract.melFrameCapacity
        mel.values.withUnsafeBufferPointer { source in
            input.mutableView(as: Float.self).withUnsafeMutablePointer { destination, _, strides in
                for channel in 0..<bins {
                    let channelBase = channel * strides[1]
                    for frame in 0..<frames {
                        destination[channelBase + frame * strides[2]] = source[frame * bins + channel]
                    }
                    for frame in frames..<capacity {
                        destination[channelBase + frame * strides[2]] = 0
                    }
                }
            }
        }
    }

    private static func write(frameCount: Int, into input: inout NDArray) {
        input.mutableView(as: Int32.self).withUnsafeMutablePointer { destination, _, _ in
            destination.pointee = Int32(frameCount)
        }
    }

    // MARK: - Outputs

    /// Reads `encoder_length`, which must equal the mel's own subsampled frame count.
    private static func encoderFrameCount(
        from outputs: inout InferenceFunction.Outputs,
        melFrameCount: Int
    ) throws -> Int {
        guard let value = outputs.remove(Contract.encoderLengthOutputName) else {
            throw CoreAIEncoderError.predictionContract(
                "\(Contract.encoderLengthOutputName) is absent"
            )
        }
        guard let array = ndArray(from: value) else {
            throw CoreAIEncoderError.predictionContract(
                "\(Contract.encoderLengthOutputName) is not an NDArray"
            )
        }
        guard array.scalarType == .int32, array.shape == [1], array.interleaveLayout == nil else {
            throw CoreAIEncoderError.predictionContract(
                "\(Contract.encoderLengthOutputName) is \(array.scalarType) \(array.shape), expected int32 [1]"
            )
        }

        let reported = Int(array.view(as: Int32.self).withUnsafePointer { pointer, _, _ in pointer.pointee })
        let expected =
            (melFrameCount + Contract.melSubsamplingFactor - 1) / Contract.melSubsamplingFactor
        guard reported == expected, reported > 0, reported <= Contract.encoderFrameCapacity else {
            throw CoreAIEncoderError.frameCountMismatch(reported: reported, expected: expected)
        }
        return reported
    }

    /// Copies the valid `[1, 1024, 188]` channel-major frames into frame-major `[frames, 1024]`,
    /// honouring the runtime's own strides, and refuses a state that is not finite.
    private static func states(
        from outputs: inout InferenceFunction.Outputs,
        frameCount: Int
    ) throws -> [Float] {
        let channels = Contract.encoderChannels
        let capacity = Contract.encoderFrameCapacity
        guard let value = outputs.remove(Contract.encoderOutputName) else {
            throw CoreAIEncoderError.predictionContract("\(Contract.encoderOutputName) is absent")
        }
        guard let array = ndArray(from: value) else {
            throw CoreAIEncoderError.predictionContract(
                "\(Contract.encoderOutputName) is not an NDArray"
            )
        }
        guard array.scalarType == .float32, array.shape == [1, channels, capacity],
            array.interleaveLayout == nil
        else {
            throw CoreAIEncoderError.predictionContract(
                "\(Contract.encoderOutputName) is \(array.scalarType) \(array.shape), expected float32 [1,\(channels),\(capacity)]"
            )
        }
        let copied = frameMajor(from: array, frames: frameCount, channels: channels)
        if copied.nonFinite, let offset = copied.values.firstIndex(where: { !$0.isFinite }) {
            throw CoreAIEncoderError.nonFiniteState(
                frame: offset / channels,
                channel: offset % channels
            )
        }
        return copied.values
    }

    private static func frameMajor(
        from states: NDArray,
        frames: Int,
        channels: Int
    ) -> (values: [Float], nonFinite: Bool) {
        var nonFinite = false
        let values = states.view(as: Float.self).withUnsafePointer { (source, _, strides) -> [Float] in
            [Float](unsafeUninitializedCapacity: frames * channels) { buffer, initializedCount in
                for frame in 0..<frames {
                    let row = frame * channels
                    let frameBase = frame * strides[2]
                    for channel in 0..<channels {
                        let value = source[channel * strides[1] + frameBase]
                        buffer[row + channel] = value
                        nonFinite = nonFinite || !value.isFinite
                    }
                }
                initializedCount = frames * channels
            }
        }
        return (values, nonFinite)
    }

    private static func ndArray(from value: consuming InferenceValue) -> NDArray? {
        value.ndArray
    }

    // MARK: - Contract

    /// Validates the declared signature before `main` is obtained: exact input and output names,
    /// scalar types, static shapes, and no state.
    private static func validate(model: AIModel, path: String) throws {
        guard model.functionNames.contains(Contract.functionName),
            let descriptor = model.functionDescriptor(for: Contract.functionName)
        else {
            throw CoreAIEncoderError.functionMissing(path: path, available: model.functionNames)
        }

        let mel = descriptor.inputDescriptor(of: Contract.melInputName)
        let melLength = descriptor.inputDescriptor(of: Contract.melLengthInputName)
        let encoder = descriptor.outputDescriptor(of: Contract.encoderOutputName)
        let encoderLength = descriptor.outputDescriptor(of: Contract.encoderLengthOutputName)
        let melShape = [1, Contract.melBins, Contract.melFrameCapacity]
        let encoderShape = [1, Contract.encoderChannels, Contract.encoderFrameCapacity]

        guard descriptor.inputCount == 2, descriptor.outputCount == 2,
            descriptor.stateNames.isEmpty,
            descriptor.inputNames == [Contract.melInputName, Contract.melLengthInputName],
            descriptor.outputNames == [Contract.encoderOutputName, Contract.encoderLengthOutputName],
            matches(mel, .float32, melShape),
            matches(melLength, .int32, [1]),
            matches(encoder, .float32, encoderShape),
            matches(encoderLength, .int32, [1])
        else {
            throw CoreAIEncoderError.modelContract(
                """
                \(path) must declare \(Contract.functionName)(\
                \(Contract.melInputName) float32 \(melShape), \
                \(Contract.melLengthInputName) int32 [1]) -> (\
                \(Contract.encoderOutputName) float32 \(encoderShape), \
                \(Contract.encoderLengthOutputName) int32 [1]) with no state; it declares \
                \(Contract.melInputName): \(summary(mel)), \
                \(Contract.melLengthInputName): \(summary(melLength)), \
                \(Contract.encoderOutputName): \(summary(encoder)), \
                \(Contract.encoderLengthOutputName): \(summary(encoderLength)), \
                states \(descriptor.stateNames)
                """
            )
        }
    }

    private static func matches(
        _ descriptor: InferenceValue.Descriptor?,
        _ scalarType: NDArray.ScalarType,
        _ shape: [Int]
    ) -> Bool {
        guard let descriptor, case .ndArray(let array) = descriptor else { return false }
        return array.scalarType == scalarType && !array.hasDynamicShape && array.shape == shape
            && array.interleaveLayout == nil
    }

    private static func summary(_ descriptor: InferenceValue.Descriptor?) -> String {
        guard let descriptor else { return "absent" }
        guard case .ndArray(let array) = descriptor else { return "an image" }
        return "\(array.scalarType) \(array.shape)\(array.hasDynamicShape ? " (dynamic)" : "")"
    }

    // MARK: - Runtime selection

    private static func specializationOptions(
        for computeUnits: CoreAIEncoderConfiguration.ComputeUnits
    ) -> SpecializationOptions {
        switch computeUnits {
        case .default:
            return .default
        case .neuralEngine:
            return SpecializationOptions(preferredComputeUnitKind: .neuralEngine)
        case .cpu:
            return .cpuOnly
        }
    }

    private static func name(of kind: ComputeUnitKind) -> String {
        switch kind {
        case .cpu:
            return "cpu"
        case .gpu:
            return "gpu"
        case .neuralEngine:
            return CoreAIEncoderConfiguration.ComputeUnits.neuralEngine.rawValue
        @unknown default:
            return "unknown"
        }
    }

    private static func milliseconds(since start: DispatchTime) -> Int {
        let elapsed = DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds
        return Int((Double(elapsed) / 1_000_000).rounded())
    }
}
