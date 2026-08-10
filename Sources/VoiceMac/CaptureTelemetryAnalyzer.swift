import Foundation
import VoiceCore

enum CaptureTelemetryAnalysisError: Error, Equatable, Sendable {
    case invalidWAV
    case unsupportedWAVFormat(formatCode: UInt16, bitsPerSample: UInt16)
}

enum CaptureTelemetryAnalyzer {
    private static let decibelFloor = -120.0
    private static let activeAmplitudeThreshold = 0.01  // -40 dBFS

    static func analyzeWAV(
        at url: URL,
        inputFormat: CaptureAudioFormat? = nil,
        processingMode: CaptureProcessingMode = .standard
    ) throws -> CaptureTelemetry {
        try analyzeWAV(
            data: Data(contentsOf: url),
            inputFormat: inputFormat,
            processingMode: processingMode
        )
    }

    static func analyzeWAV(
        data: Data,
        inputFormat: CaptureAudioFormat? = nil,
        processingMode: CaptureProcessingMode = .standard,
        routeChangeCount: Int = 0,
        droppedBufferCount: Int = 0
    ) throws -> CaptureTelemetry {
        let wav = try parseWAV(data)
        let outputFormat = CaptureAudioFormat(
            sampleRateHz: wav.sampleRateHz,
            channels: wav.channels,
            encoding: wav.encoding
        )
        let metrics = data.withUnsafeBytes { bytes in
            statistics(
                sampleCount: wav.frameCount * wav.channels,
                sampleRateHz: wav.sampleRateHz,
                channels: wav.channels,
                clipThreshold: wav.clipThreshold
            ) { sampleIndex in
                wav.sample(at: sampleIndex, bytes: bytes)
            }
        }

        return telemetry(
            metrics: metrics,
            inputFormat: inputFormat ?? outputFormat,
            outputFormat: outputFormat,
            processingMode: processingMode,
            routeChangeCount: routeChangeCount,
            droppedBufferCount: droppedBufferCount,
            zeroBufferCount: metrics.zeroBufferCount
        )
    }

    /// Analyzes normalized, interleaved Float PCM collected by an experimental capture path.
    /// Non-finite samples are treated as zero so every emitted metric remains finite.
    static func analyze(
        samples: [Float],
        sampleRateHz: Int,
        channels: Int,
        outputFormat: CaptureAudioFormat,
        processingMode: CaptureProcessingMode,
        routeChangeCount: Int,
        droppedBufferCount: Int,
        zeroBufferCount: Int
    ) -> CaptureTelemetry {
        let safeSampleRate = max(1, sampleRateHz)
        let safeChannels = max(1, channels)
        let completeSampleCount = samples.count - samples.count % safeChannels
        let metrics = statistics(
            sampleCount: completeSampleCount,
            sampleRateHz: safeSampleRate,
            channels: safeChannels,
            clipThreshold: 1.0
        ) { index in
            let value = Double(samples[index])
            return value.isFinite ? value : 0
        }
        let inputFormat = CaptureAudioFormat(
            sampleRateHz: sampleRateHz,
            channels: channels,
            encoding: "pcm_f32"
        )

        return telemetry(
            metrics: metrics,
            inputFormat: inputFormat,
            outputFormat: outputFormat,
            processingMode: processingMode,
            routeChangeCount: routeChangeCount,
            droppedBufferCount: droppedBufferCount,
            zeroBufferCount: zeroBufferCount
        )
    }

    private static func telemetry(
        metrics: Metrics,
        inputFormat: CaptureAudioFormat,
        outputFormat: CaptureAudioFormat,
        processingMode: CaptureProcessingMode,
        routeChangeCount: Int,
        droppedBufferCount: Int,
        zeroBufferCount: Int
    ) -> CaptureTelemetry {
        CaptureTelemetry(
            inputFormat: inputFormat,
            outputFormat: outputFormat,
            clipRatio: metrics.clipRatio,
            activeSpeechRatio: metrics.activeSpeechRatio,
            peakDBFS: metrics.peakDBFS,
            noiseFloorDBFS: metrics.noiseFloorDBFS,
            snrDB: metrics.snrDB,
            leadingSilenceMs: metrics.leadingSilenceMs,
            trailingSilenceMs: metrics.trailingSilenceMs,
            routeChangeCount: max(0, routeChangeCount),
            droppedBufferCount: max(0, droppedBufferCount),
            zeroBufferCount: max(0, zeroBufferCount),
            processingMode: processingMode
        )
    }

    private static func statistics(
        sampleCount: Int,
        sampleRateHz: Int,
        channels: Int,
        clipThreshold: Double,
        sampleAt: (Int) -> Double
    ) -> Metrics {
        guard sampleCount > 0, sampleRateHz > 0, channels > 0 else {
            return .empty
        }

        let frameCount = sampleCount / channels
        guard frameCount > 0 else { return .empty }

        let framesPerBuffer = max(1, sampleRateHz / 100)  // deterministic 10 ms analysis buffers
        var clipCount = 0
        var activeFrameCount = 0
        var firstActiveFrame: Int?
        var lastActiveFrame: Int?
        var peak = 0.0
        var bufferPeak = 0.0
        var bufferEnergy = 0.0
        var bufferSampleCount = 0
        var bufferRMS: [Double] = []
        bufferRMS.reserveCapacity((frameCount + framesPerBuffer - 1) / framesPerBuffer)
        var derivedZeroBufferCount = 0

        for frame in 0..<frameCount {
            var framePeak = 0.0
            for channel in 0..<channels {
                let raw = sampleAt(frame * channels + channel)
                let sample = raw.isFinite ? raw : 0
                let magnitude = abs(sample)
                peak = max(peak, magnitude)
                framePeak = max(framePeak, magnitude)
                bufferPeak = max(bufferPeak, magnitude)
                bufferEnergy += sample * sample
                bufferSampleCount += 1
                if magnitude >= clipThreshold {
                    clipCount += 1
                }
            }

            if framePeak >= activeAmplitudeThreshold {
                activeFrameCount += 1
                if firstActiveFrame == nil { firstActiveFrame = frame }
                lastActiveFrame = frame
            }

            let closesBuffer = (frame + 1) % framesPerBuffer == 0 || frame + 1 == frameCount
            if closesBuffer {
                if bufferPeak == 0 { derivedZeroBufferCount += 1 }
                let rms = bufferSampleCount == 0 ? 0 : sqrt(bufferEnergy / Double(bufferSampleCount))
                bufferRMS.append(rms.isFinite ? rms : 0)
                bufferPeak = 0
                bufferEnergy = 0
                bufferSampleCount = 0
            }
        }

        let sortedBufferRMS = bufferRMS.sorted()
        let peakDBFS = decibels(peak)
        let noiseFloorDBFS = decibels(percentile(sortedBufferRMS, fraction: 0.10))
        let activeLevelDBFS = decibels(percentile(sortedBufferRMS, fraction: 0.90))
        let snrDB = min(240, max(0, activeLevelDBFS - noiseFloorDBFS))
        let durationMs = milliseconds(frames: frameCount, sampleRateHz: sampleRateHz)
        let leadingSilenceMs: Int
        let trailingSilenceMs: Int
        if let firstActiveFrame, let lastActiveFrame {
            leadingSilenceMs = milliseconds(frames: firstActiveFrame, sampleRateHz: sampleRateHz)
            trailingSilenceMs = milliseconds(
                frames: frameCount - lastActiveFrame - 1,
                sampleRateHz: sampleRateHz
            )
        } else {
            leadingSilenceMs = durationMs
            trailingSilenceMs = durationMs
        }

        return Metrics(
            clipRatio: Double(clipCount) / Double(frameCount * channels),
            activeSpeechRatio: Double(activeFrameCount) / Double(frameCount),
            peakDBFS: peakDBFS,
            noiseFloorDBFS: noiseFloorDBFS,
            snrDB: snrDB,
            leadingSilenceMs: leadingSilenceMs,
            trailingSilenceMs: trailingSilenceMs,
            zeroBufferCount: derivedZeroBufferCount
        )
    }

    private static func decibels(_ amplitude: Double) -> Double {
        guard amplitude.isFinite, amplitude > 0 else { return decibelFloor }
        return max(decibelFloor, 20 * log10(amplitude))
    }

    private static func percentile(_ sortedValues: [Double], fraction: Double) -> Double {
        guard !sortedValues.isEmpty else { return 0 }
        let index = Int((Double(sortedValues.count - 1) * fraction).rounded())
        return sortedValues[min(max(index, 0), sortedValues.count - 1)]
    }

    private static func milliseconds(frames: Int, sampleRateHz: Int) -> Int {
        guard frames > 0, sampleRateHz > 0 else { return 0 }
        return Int((Double(frames) * 1_000 / Double(sampleRateHz)).rounded())
    }

    private static func parseWAV(_ data: Data) throws -> WAVLayout {
        guard data.count >= 12,
            chunkID(data, at: 0) == "RIFF",
            chunkID(data, at: 8) == "WAVE"
        else {
            throw CaptureTelemetryAnalysisError.invalidWAV
        }

        var formatCode: UInt16?
        var channels: Int?
        var sampleRateHz: Int?
        var blockAlign: Int?
        var bitsPerSample: UInt16?
        var dataOffset: Int?
        var dataByteCount: Int?
        var offset = 12

        while offset <= data.count - 8 {
            let size = Int(readUInt32(data, at: offset + 4))
            let payloadOffset = offset + 8
            guard size >= 0, payloadOffset <= data.count, size <= data.count - payloadOffset else {
                throw CaptureTelemetryAnalysisError.invalidWAV
            }

            switch chunkID(data, at: offset) {
            case "fmt ":
                guard size >= 16 else { throw CaptureTelemetryAnalysisError.invalidWAV }
                formatCode = readUInt16(data, at: payloadOffset)
                channels = Int(readUInt16(data, at: payloadOffset + 2))
                sampleRateHz = Int(readUInt32(data, at: payloadOffset + 4))
                blockAlign = Int(readUInt16(data, at: payloadOffset + 12))
                bitsPerSample = readUInt16(data, at: payloadOffset + 14)
            case "data":
                dataOffset = payloadOffset
                dataByteCount = size
            default:
                break
            }

            let paddedSize = size + (size & 1)
            guard paddedSize <= data.count - payloadOffset else {
                throw CaptureTelemetryAnalysisError.invalidWAV
            }
            offset = payloadOffset + paddedSize
        }

        guard let formatCode,
            let channels,
            let sampleRateHz,
            let blockAlign,
            let bitsPerSample,
            let dataOffset,
            let dataByteCount,
            channels > 0,
            sampleRateHz > 0,
            blockAlign > 0
        else {
            throw CaptureTelemetryAnalysisError.invalidWAV
        }

        let bytesPerSample = Int(bitsPerSample) / 8
        guard bitsPerSample % 8 == 0,
            bytesPerSample > 0,
            blockAlign >= channels * bytesPerSample
        else {
            throw CaptureTelemetryAnalysisError.invalidWAV
        }

        let encoding: String
        let clipThreshold: Double
        switch (formatCode, bitsPerSample) {
        case (1, 8):
            encoding = "pcm_u8"
            clipThreshold = 127.0 / 128.0
        case (1, 16):
            encoding = "pcm_s16le"
            clipThreshold = 32_767.0 / 32_768.0
        case (1, 24):
            encoding = "pcm_s24le"
            clipThreshold = 8_388_607.0 / 8_388_608.0
        case (1, 32):
            encoding = "pcm_s32le"
            clipThreshold = 2_147_483_647.0 / 2_147_483_648.0
        case (3, 32):
            encoding = "pcm_f32le"
            clipThreshold = 1.0
        case (3, 64):
            encoding = "pcm_f64le"
            clipThreshold = 1.0
        default:
            throw CaptureTelemetryAnalysisError.unsupportedWAVFormat(
                formatCode: formatCode,
                bitsPerSample: bitsPerSample
            )
        }

        return WAVLayout(
            formatCode: formatCode,
            channels: channels,
            sampleRateHz: sampleRateHz,
            blockAlign: blockAlign,
            bitsPerSample: Int(bitsPerSample),
            bytesPerSample: bytesPerSample,
            dataOffset: dataOffset,
            frameCount: dataByteCount / blockAlign,
            encoding: encoding,
            clipThreshold: clipThreshold
        )
    }

    private static func chunkID(_ data: Data, at offset: Int) -> String {
        guard offset >= 0, offset <= data.count - 4 else { return "" }
        return String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }

    private struct WAVLayout {
        var formatCode: UInt16
        var channels: Int
        var sampleRateHz: Int
        var blockAlign: Int
        var bitsPerSample: Int
        var bytesPerSample: Int
        var dataOffset: Int
        var frameCount: Int
        var encoding: String
        var clipThreshold: Double

        func sample(at sampleIndex: Int, bytes: UnsafeRawBufferPointer) -> Double {
            let frame = sampleIndex / channels
            let channel = sampleIndex % channels
            let offset = dataOffset + frame * blockAlign + channel * bytesPerSample
            let value: Double

            switch (formatCode, bitsPerSample) {
            case (1, 8):
                value = Double(Int(bytes[offset]) - 128) / 128.0
            case (1, 16):
                let bits = UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
                value = Double(Int16(bitPattern: bits)) / 32_768.0
            case (1, 24):
                var integer =
                    Int32(bytes[offset])
                    | Int32(bytes[offset + 1]) << 8
                    | Int32(bytes[offset + 2]) << 16
                if integer & 0x0080_0000 != 0 {
                    integer |= ~0x00ff_ffff
                }
                value = Double(integer) / 8_388_608.0
            case (1, 32):
                let bits =
                    UInt32(bytes[offset])
                    | UInt32(bytes[offset + 1]) << 8
                    | UInt32(bytes[offset + 2]) << 16
                    | UInt32(bytes[offset + 3]) << 24
                value = Double(Int32(bitPattern: bits)) / 2_147_483_648.0
            case (3, 32):
                let bits =
                    UInt32(bytes[offset])
                    | UInt32(bytes[offset + 1]) << 8
                    | UInt32(bytes[offset + 2]) << 16
                    | UInt32(bytes[offset + 3]) << 24
                value = Double(Float(bitPattern: bits))
            case (3, 64):
                var bits: UInt64 = 0
                for byte in 0..<8 {
                    bits |= UInt64(bytes[offset + byte]) << (byte * 8)
                }
                value = Double(bitPattern: bits)
            default:
                return 0
            }

            return value.isFinite ? value : 0
        }
    }

    private struct Metrics {
        var clipRatio: Double
        var activeSpeechRatio: Double
        var peakDBFS: Double
        var noiseFloorDBFS: Double
        var snrDB: Double
        var leadingSilenceMs: Int
        var trailingSilenceMs: Int
        var zeroBufferCount: Int

        static let empty = Metrics(
            clipRatio: 0,
            activeSpeechRatio: 0,
            peakDBFS: CaptureTelemetryAnalyzer.decibelFloor,
            noiseFloorDBFS: CaptureTelemetryAnalyzer.decibelFloor,
            snrDB: 0,
            leadingSilenceMs: 0,
            trailingSilenceMs: 0,
            zeroBufferCount: 0
        )
    }
}
