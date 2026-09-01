import CoreML
import Foundation

struct CoreMLEncoderConfiguration: Equatable {
    enum Bucket: Equatable {
        case short
        case tiny
        case standard

        var modelEnvironmentKey: String {
            switch self {
            case .short:
                return "VOICEOUR_COREML_ENCODER_SHORT"
            case .tiny:
                return "VOICEOUR_COREML_ENCODER_TINY"
            case .standard:
                return "VOICEOUR_COREML_ENCODER"
            }
        }

        var maximumDurationEnvironmentKey: String {
            switch self {
            case .short:
                return "VOICEOUR_COREML_SHORT_MAX_S"
            case .tiny:
                return "VOICEOUR_COREML_TINY_MAX_S"
            case .standard:
                return "VOICEOUR_COREML_MAX_S"
            }
        }

        var defaultMaximumDurationSeconds: Double {
            switch self {
            case .short:
                return 8.0
            case .tiny:
                return 6.0
            case .standard:
                return 15.0
            }
        }

        var modelMaximumDurationSeconds: Double {
            defaultMaximumDurationSeconds
        }

        var melFrameCapacity: Int {
            switch self {
            case .short:
                return 801
            case .tiny:
                return 601
            case .standard:
                return 1_501
            }
        }

        var encoderFrameCapacity: Int {
            switch self {
            case .short:
                return 101
            case .tiny:
                return 76
            case .standard:
                return 188
            }
        }
    }

    private static let sampleRate = 16_000

    let bucket: Bucket
    let modelURL: URL
    let maximumDurationSeconds: Double
    let maximumSampleCount: Int
    let melFrameCapacity: Int
    let encoderFrameCapacity: Int

    fileprivate static func resolve(
        environment: [String: String],
        bucket: Bucket
    ) throws -> CoreMLEncoderConfiguration? {
        guard let modelPath = environment[bucket.modelEnvironmentKey] else { return nil }
        guard !modelPath.isEmpty else {
            throw CoreMLEncoderError.emptyModelPath(bucket.modelEnvironmentKey)
        }

        let maximumDurationSeconds: Double
        if let rawMaximum = environment[bucket.maximumDurationEnvironmentKey] {
            guard let parsed = Double(rawMaximum), parsed.isFinite, parsed > 0,
                  parsed <= bucket.modelMaximumDurationSeconds
            else {
                throw CoreMLEncoderError.invalidMaximumDuration(
                    name: bucket.maximumDurationEnvironmentKey,
                    value: rawMaximum,
                    maximum: bucket.modelMaximumDurationSeconds
                )
            }
            maximumDurationSeconds = parsed
        } else {
            maximumDurationSeconds = bucket.defaultMaximumDurationSeconds
        }

        return CoreMLEncoderConfiguration(
            bucket: bucket,
            modelURL: URL(fileURLWithPath: modelPath),
            maximumDurationSeconds: maximumDurationSeconds,
            maximumSampleCount: Int(maximumDurationSeconds * Double(sampleRate)),
            melFrameCapacity: bucket.melFrameCapacity,
            encoderFrameCapacity: bucket.encoderFrameCapacity
        )
    }

    func routesThroughCoreML(sampleCount: Int) -> Bool {
        sampleCount <= maximumSampleCount
    }
}

struct CoreMLEncoderConfigurationSet: Equatable {
    let standard: CoreMLEncoderConfiguration?
    let short: CoreMLEncoderConfiguration?
    let tiny: CoreMLEncoderConfiguration?

    static func resolve(environment: [String: String]) throws -> CoreMLEncoderConfigurationSet {
        CoreMLEncoderConfigurationSet(
            standard: try CoreMLEncoderConfiguration.resolve(
                environment: environment,
                bucket: .standard
            ),
            short: try CoreMLEncoderConfiguration.resolve(
                environment: environment,
                bucket: .short
            ),
            tiny: try CoreMLEncoderConfiguration.resolve(
                environment: environment,
                bucket: .tiny
            )
        )
    }

    func selectedConfiguration(sampleCount: Int) -> CoreMLEncoderConfiguration? {
        if let tiny, tiny.routesThroughCoreML(sampleCount: sampleCount) {
            return tiny
        }
        if let short, short.routesThroughCoreML(sampleCount: sampleCount) {
            return short
        }
        if let standard, standard.routesThroughCoreML(sampleCount: sampleCount) {
            return standard
        }
        return nil
    }
}

enum CoreMLEncoderError: Error, CustomStringConvertible {
    case emptyModelPath(String)
    case invalidMaximumDuration(name: String, value: String, maximum: Double)
    case modelMissing(String)
    case unsupportedModelPath(String)
    case modelCompilationFailed(String)
    case modelLoadFailed(String)
    case modelContract(String)
    case nativeMelContract(String)
    case predictionFailed(String)
    case predictionContract(String)

    var description: String {
        switch self {
        case .emptyModelPath(let name):
            return "\(name) is set but empty"
        case .invalidMaximumDuration(let name, let value, let maximum):
            return "\(name) must be a finite value greater than 0 and no greater than \(maximum); got \(value.debugDescription)"
        case .modelMissing(let path):
            return "CoreML encoder does not exist at \(path)"
        case .unsupportedModelPath(let path):
            return "CoreML encoder must be a .mlmodelc or .mlpackage: \(path)"
        case .modelCompilationFailed(let detail):
            return "CoreML encoder compilation failed: \(detail)"
        case .modelLoadFailed(let detail):
            return "CoreML encoder load failed: \(detail)"
        case .modelContract(let detail):
            return "CoreML encoder model contract failed: \(detail)"
        case .nativeMelContract(let detail):
            return "native mel contract failed: \(detail)"
        case .predictionFailed(let detail):
            return "CoreML encoder prediction failed: \(detail)"
        case .predictionContract(let detail):
            return "CoreML encoder prediction contract failed: \(detail)"
        }
    }
}

/// One fixed-shape, synchronous CoreML encoder. The model, input arrays, feature provider, and
/// frame-major output buffer are created once and reused by the persistent sidecar.
final class CoreMLEncoder {
    static let melBins = 128
    static let encoderChannels = 1_024

    private let model: MLModel
    private let mel: MLMultiArray
    private let melLength: MLMultiArray
    private let provider: MLDictionaryFeatureProvider
    private let melChannelStride: Int
    private let melFrameStride: Int
    private let melFrameCapacity: Int
    private let encoderFrameCapacity: Int
    private var frameMajorStates: [Float]

    init(configuration: CoreMLEncoderConfiguration) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: configuration.modelURL.path) else {
            throw CoreMLEncoderError.modelMissing(configuration.modelURL.path)
        }

        let loaded: (MLModel, MLMultiArray, MLMultiArray, MLDictionaryFeatureProvider, Int, Int)
        do {
            loaded = try autoreleasepool {
                let modelURL: URL
                switch configuration.modelURL.pathExtension.lowercased() {
                case "mlmodelc":
                    modelURL = configuration.modelURL
                case "mlpackage":
                    do {
                        modelURL = try MLModel.compileModel(at: configuration.modelURL)
                    } catch {
                        throw CoreMLEncoderError.modelCompilationFailed(String(describing: error))
                    }
                default:
                    throw CoreMLEncoderError.unsupportedModelPath(configuration.modelURL.path)
                }

                let modelConfiguration = MLModelConfiguration()
                modelConfiguration.computeUnits = .cpuAndNeuralEngine
                let model: MLModel
                do {
                    model = try MLModel(contentsOf: modelURL, configuration: modelConfiguration)
                } catch {
                    throw CoreMLEncoderError.modelLoadFailed(String(describing: error))
                }
                try Self.validate(model: model, configuration: configuration)

                let mel = try MLMultiArray(
                    shape: [
                        1,
                        NSNumber(value: Self.melBins),
                        NSNumber(value: configuration.melFrameCapacity),
                    ],
                    dataType: .float32
                )
                let melLength = try MLMultiArray(shape: [1], dataType: .int32)
                guard mel.strides.count == 3,
                      mel.count == Self.melBins * configuration.melFrameCapacity
                else {
                    throw CoreMLEncoderError.modelContract(
                        "allocated mel storage has unexpected strides or count"
                    )
                }
                let provider = try MLDictionaryFeatureProvider(
                    dictionary: ["mel": mel, "mel_length": melLength]
                )
                return (
                    model,
                    mel,
                    melLength,
                    provider,
                    mel.strides[1].intValue,
                    mel.strides[2].intValue
                )
            }
        } catch let error as CoreMLEncoderError {
            throw error
        } catch {
            throw CoreMLEncoderError.modelLoadFailed(String(describing: error))
        }

        model = loaded.0
        mel = loaded.1
        melLength = loaded.2
        provider = loaded.3
        melChannelStride = loaded.4
        melFrameStride = loaded.5
        melFrameCapacity = configuration.melFrameCapacity
        encoderFrameCapacity = configuration.encoderFrameCapacity
        frameMajorStates = [Float](
            repeating: 0,
            count: Self.encoderChannels * configuration.encoderFrameCapacity
        )
    }

    /// Transposes native frame-major mel into the fixed BCT input, predicts synchronously, copies
    /// the valid CoreML output into reusable frame-major storage, then lends that storage to C.
    func encode(
        nativeMel: UnsafeBufferPointer<Float>,
        frameCount: Int,
        consume: (UnsafeBufferPointer<Float>, Int) -> Int32
    ) throws -> Int32 {
        guard frameCount > 0, frameCount <= melFrameCapacity,
              nativeMel.count == frameCount * Self.melBins
        else {
            throw CoreMLEncoderError.nativeMelContract(
                "expected [frames,128] with 1...\(melFrameCapacity) frames; got \(nativeMel.count) values over \(frameCount) frames"
            )
        }

        guard mel.count == Self.melBins * melFrameCapacity else {
            throw CoreMLEncoderError.modelContract("runtime mel storage count changed")
        }
        let destination = mel.dataPointer.assumingMemoryBound(to: Float.self)
        destination.update(repeating: 0, count: mel.count)
        for frame in 0..<frameCount {
            for channel in 0..<Self.melBins {
                destination[channel * melChannelStride + frame * melFrameStride] =
                    nativeMel[frame * Self.melBins + channel]
            }
        }
        melLength.dataPointer.assumingMemoryBound(to: Int32.self).pointee = Int32(frameCount)

        let encoderFrameCount: Int = try autoreleasepool {
            let features: MLFeatureProvider
            do {
                features = try model.prediction(from: provider)
            } catch {
                throw CoreMLEncoderError.predictionFailed(String(describing: error))
            }
            guard let encoder = features.featureValue(for: "encoder")?.multiArrayValue,
                  let encoderLength = features.featureValue(for: "encoder_length")?.multiArrayValue,
                  encoder.dataType == .float32,
                  encoderLength.dataType == .int32,
                  encoder.shape.count == 3,
                  encoder.shape[0].intValue == 1,
                  encoder.shape[1].intValue == Self.encoderChannels,
                  encoder.shape[2].intValue == encoderFrameCapacity,
                  encoderLength.shape.count == 1,
                  encoderLength.shape[0].intValue == 1
            else {
                throw CoreMLEncoderError.predictionContract("output names, dtypes, or shapes changed")
            }

            let validFrames = Int(
                encoderLength.dataPointer.assumingMemoryBound(to: Int32.self).pointee
            )
            let expectedFrames = (frameCount + 7) / 8
            guard validFrames == expectedFrames, validFrames > 0,
                  validFrames <= encoderFrameCapacity
            else {
                throw CoreMLEncoderError.predictionContract(
                    "encoder_length \(validFrames) does not equal subsampled mel length \(expectedFrames)"
                )
            }

            let source = encoder.dataPointer.assumingMemoryBound(to: Float.self)
            guard encoder.strides.count == 3 else {
                throw CoreMLEncoderError.predictionContract("encoder output has unexpected strides")
            }
            let channelStride = encoder.strides[1].intValue
            let frameStride = encoder.strides[2].intValue
            for frame in 0..<validFrames {
                for channel in 0..<Self.encoderChannels {
                    frameMajorStates[frame * Self.encoderChannels + channel] =
                        source[channel * channelStride + frame * frameStride]
                }
            }
            return validFrames
        }

        return frameMajorStates.withUnsafeBufferPointer { states in
            consume(
                UnsafeBufferPointer(rebasing: states.prefix(encoderFrameCount * Self.encoderChannels)),
                encoderFrameCount
            )
        }
    }

    private static func validate(
        model: MLModel,
        configuration: CoreMLEncoderConfiguration
    ) throws {
        let inputs = model.modelDescription.inputDescriptionsByName
        let outputs = model.modelDescription.outputDescriptionsByName
        guard inputs.count == 2, outputs.count == 2,
              let mel = inputs["mel"]?.multiArrayConstraint,
              let melLength = inputs["mel_length"]?.multiArrayConstraint,
              let encoder = outputs["encoder"]?.multiArrayConstraint,
              let encoderLength = outputs["encoder_length"]?.multiArrayConstraint,
              mel.dataType == .float32,
              melLength.dataType == .int32,
              encoder.dataType == .float32,
              encoderLength.dataType == .int32,
              mel.shape.map(\.intValue) == [1, melBins, configuration.melFrameCapacity],
              melLength.shape.map(\.intValue) == [1],
              encoder.shape.map(\.intValue) == [
                  1,
                  encoderChannels,
                  configuration.encoderFrameCapacity,
              ],
              encoderLength.shape.map(\.intValue) == [1]
        else {
            throw CoreMLEncoderError.modelContract(
                "expected mel[1,128,\(configuration.melFrameCapacity)] f32, mel_length[1] i32 -> encoder[1,1024,\(configuration.encoderFrameCapacity)] f32, encoder_length[1] i32"
            )
        }
    }

}

/// Owns one persistent CoreML client per configured fixed-shape artifact.
final class CoreMLEncoderSet {
    private let configurations: CoreMLEncoderConfigurationSet
    private let standard: CoreMLEncoder?
    private let short: CoreMLEncoder?
    private let tiny: CoreMLEncoder?

    var isEmpty: Bool {
        standard == nil && short == nil && tiny == nil
    }

    init(configurations: CoreMLEncoderConfigurationSet) throws {
        self.configurations = configurations
        tiny = try configurations.tiny.map(CoreMLEncoder.init(configuration:))
        short = try configurations.short.map(CoreMLEncoder.init(configuration:))
        standard = try configurations.standard.map(CoreMLEncoder.init(configuration:))
    }

    func encoder(sampleCount: Int) -> CoreMLEncoder? {
        switch configurations.selectedConfiguration(sampleCount: sampleCount)?.bucket {
        case .tiny:
            return tiny
        case .short:
            return short
        case .standard:
            return standard
        case nil:
            return nil
        }
    }
}
