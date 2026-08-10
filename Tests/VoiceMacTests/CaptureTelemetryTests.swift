import Foundation
import Testing

@testable import VoiceCore
@testable import VoiceMac

/// Covers WAV-derived capture telemetry and deterministic fake-recorder metrics.
@Suite("Capture Telemetry")
struct CaptureTelemetryTests {
    @Test func captureTelemetryDefinesEmptyWAVMetrics() throws {
        let telemetry = try CaptureTelemetryAnalyzer.analyzeWAV(
            data: pcm16WAV(samples: [], sampleRateHz: 1_000)
        )

        #expect(
            telemetry.outputFormat
                == CaptureAudioFormat(
                    sampleRateHz: 1_000,
                    channels: 1,
                    encoding: "pcm_s16le"
                ))
        #expect(telemetry.clipRatio == 0)
        #expect(telemetry.activeSpeechRatio == 0)
        #expect(telemetry.peakDBFS == -120)
        #expect(telemetry.noiseFloorDBFS == -120)
        #expect(telemetry.snrDB == 0)
        #expect(telemetry.leadingSilenceMs == 0)
        #expect(telemetry.trailingSilenceMs == 0)
        #expect(telemetry.zeroBufferCount == 0)
        expectFiniteCaptureMetrics(telemetry)
    }

    @Test func captureTelemetryDefinesSilentWAVMetrics() throws {
        let telemetry = try CaptureTelemetryAnalyzer.analyzeWAV(
            data: pcm16WAV(samples: [Int16](repeating: 0, count: 100), sampleRateHz: 1_000)
        )

        #expect(telemetry.clipRatio == 0)
        #expect(telemetry.activeSpeechRatio == 0)
        #expect(telemetry.peakDBFS == -120)
        #expect(telemetry.noiseFloorDBFS == -120)
        #expect(telemetry.snrDB == 0)
        #expect(telemetry.leadingSilenceMs == 100)
        #expect(telemetry.trailingSilenceMs == 100)
        #expect(telemetry.zeroBufferCount == 10)
        expectFiniteCaptureMetrics(telemetry)
    }

    @Test func captureTelemetryDefinesClippedWAVMetrics() throws {
        let samples = (0..<100).map { $0.isMultiple(of: 2) ? Int16.max : Int16.min }
        let telemetry = try CaptureTelemetryAnalyzer.analyzeWAV(
            data: pcm16WAV(samples: samples, sampleRateHz: 1_000)
        )

        #expect(telemetry.clipRatio == 1)
        #expect(telemetry.activeSpeechRatio == 1)
        #expect(telemetry.peakDBFS == 0)
        #expect(telemetry.snrDB >= 0)
        #expect(telemetry.leadingSilenceMs == 0)
        #expect(telemetry.trailingSilenceMs == 0)
        #expect(telemetry.zeroBufferCount == 0)
        expectFiniteCaptureMetrics(telemetry)
    }

    @Test func captureTelemetryDefinesNormalWAVAndCaptureCounters() throws {
        let samples =
            [Int16](repeating: 0, count: 20)
            + [Int16](repeating: 8_192, count: 60)
            + [Int16](repeating: 0, count: 20)
        let inputFormat = CaptureAudioFormat(
            sampleRateHz: 48_000,
            channels: 2,
            encoding: "pcm_f32"
        )
        let telemetry = try CaptureTelemetryAnalyzer.analyzeWAV(
            data: pcm16WAV(samples: samples, sampleRateHz: 1_000),
            inputFormat: inputFormat,
            processingMode: .voiceProcessingNoAGC,
            routeChangeCount: 2,
            droppedBufferCount: 3
        )

        #expect(telemetry.inputFormat == inputFormat)
        #expect(
            telemetry.outputFormat
                == CaptureAudioFormat(
                    sampleRateHz: 1_000,
                    channels: 1,
                    encoding: "pcm_s16le"
                ))
        #expect(telemetry.clipRatio == 0)
        #expect(telemetry.activeSpeechRatio == 0.6)
        #expect(telemetry.peakDBFS < -12)
        #expect(telemetry.peakDBFS > -13)
        #expect(telemetry.noiseFloorDBFS == -120)
        #expect(telemetry.snrDB > 100)
        #expect(telemetry.leadingSilenceMs == 20)
        #expect(telemetry.trailingSilenceMs == 20)
        #expect(telemetry.routeChangeCount == 2)
        #expect(telemetry.droppedBufferCount == 3)
        #expect(telemetry.zeroBufferCount == 4)
        #expect(telemetry.processingMode == .voiceProcessingNoAGC)
        expectFiniteCaptureMetrics(telemetry)
    }

    @Test func fakeRecorderEmitsDeterministicCaptureTelemetry() async throws {
        let recorder = FakeAudioRecorder()
        try recorder.start()
        let audio = try await recorder.stop()
        defer { try? FileManager.default.removeItem(at: audio.url) }
        let telemetry = try #require(audio.telemetry)

        #expect(
            telemetry.inputFormat
                == CaptureAudioFormat(
                    sampleRateHz: 16_000,
                    channels: 1,
                    encoding: "pcm_s16le"
                ))
        #expect(telemetry.outputFormat == telemetry.inputFormat)
        #expect(telemetry.clipRatio == 0)
        #expect(telemetry.activeSpeechRatio == 0)
        #expect(telemetry.leadingSilenceMs == 100)
        #expect(telemetry.trailingSilenceMs == 100)
        #expect(telemetry.zeroBufferCount == 10)
        #expect(telemetry.routeChangeCount == 0)
        #expect(telemetry.droppedBufferCount == 0)
        #expect(telemetry.processingMode == .standard)
        expectFiniteCaptureMetrics(telemetry)
    }

    private func pcm16WAV(samples: [Int16], sampleRateHz: Int) -> Data {
        let channels = 1
        let dataByteCount = samples.count * MemoryLayout<Int16>.size
        var data = Data()
        func appendString(_ value: String) {
            data.append(contentsOf: value.utf8)
        }
        func appendUInt16(_ value: UInt16) {
            var littleEndian = value.littleEndian
            data.append(Data(bytes: &littleEndian, count: MemoryLayout<UInt16>.size))
        }
        func appendUInt32(_ value: UInt32) {
            var littleEndian = value.littleEndian
            data.append(Data(bytes: &littleEndian, count: MemoryLayout<UInt32>.size))
        }

        appendString("RIFF")
        appendUInt32(UInt32(36 + dataByteCount))
        appendString("WAVE")
        appendString("fmt ")
        appendUInt32(16)
        appendUInt16(1)
        appendUInt16(UInt16(channels))
        appendUInt32(UInt32(sampleRateHz))
        appendUInt32(UInt32(sampleRateHz * channels * MemoryLayout<Int16>.size))
        appendUInt16(UInt16(channels * MemoryLayout<Int16>.size))
        appendUInt16(16)
        appendString("data")
        appendUInt32(UInt32(dataByteCount))
        for sample in samples {
            appendUInt16(UInt16(bitPattern: sample))
        }
        return data
    }

    private func expectFiniteCaptureMetrics(_ telemetry: CaptureTelemetry) {
        #expect(telemetry.clipRatio.isFinite)
        #expect(telemetry.activeSpeechRatio.isFinite)
        #expect(telemetry.peakDBFS.isFinite)
        #expect(telemetry.noiseFloorDBFS.isFinite)
        #expect(telemetry.snrDB.isFinite)
    }

}
