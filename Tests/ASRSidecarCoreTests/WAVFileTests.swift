import Foundation
import Testing

@testable import ASRSidecarCore

@Suite("WAVFileTests")
struct WAVFileTests {
    /// Builds a canonical RIFF/WAVE header plus PCM payload so each rejection test can move
    /// exactly one field away from what the recorder writes.
    private func wav(
        samples: [Int16],
        audioFormat: UInt16 = 1,
        channels: UInt16 = 1,
        sampleRate: UInt32 = 16000,
        bitsPerSample: UInt16 = 16
    ) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let payloadBytes = UInt32(samples.count * 2)
        let blockAlign = UInt16(channels * bitsPerSample / 8)

        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + payloadBytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))
        append(audioFormat)
        append(channels)
        append(sampleRate)
        append(sampleRate * UInt32(blockAlign))
        append(blockAlign)
        append(bitsPerSample)
        data.append(contentsOf: Array("data".utf8))
        append(payloadBytes)
        for sample in samples { append(sample) }
        return data
    }

    @Test func decodesTheRecordersOwnFormatToNormalizedFloats() throws {
        let data = wav(samples: [0, 32767, -32768, 16384])

        let samples = try WAVFile.readSamples(from: data)

        #expect(samples.count == 4)
        #expect(samples[0] == 0)
        #expect(abs(samples[1] - 0.999969) < 1e-5)
        #expect(samples[2] == -1)
        #expect(samples[3] == 0.5)
    }

    @Test func skipsUnknownChunksBeforeData() throws {
        var data = wav(samples: [1000, -1000])
        // Splice a LIST chunk between fmt and data, which real writers emit.
        let dataChunkStart = 36
        var spliced = data.prefix(dataChunkStart)
        spliced.append(contentsOf: Array("LIST".utf8))
        withUnsafeBytes(of: UInt32(4).littleEndian) { spliced.append(contentsOf: $0) }
        spliced.append(contentsOf: Array("INFO".utf8))
        spliced.append(contentsOf: data.suffix(from: dataChunkStart))
        data = Data(spliced)

        let samples = try WAVFile.readSamples(from: data)

        #expect(samples.count == 2)
    }

    @Test func rejectsStereo() {
        #expect(throws: WAVFileError.self) {
            try WAVFile.readSamples(from: wav(samples: [0, 0], channels: 2))
        }
    }

    @Test func rejectsEightBit() {
        #expect(throws: WAVFileError.self) {
            try WAVFile.readSamples(from: wav(samples: [0, 0], bitsPerSample: 8))
        }
    }

    @Test func rejectsFortyFourOneKilohertz() {
        #expect(throws: WAVFileError.self) {
            try WAVFile.readSamples(from: wav(samples: [0, 0], sampleRate: 44100))
        }
    }

    @Test func rejectsNonPCMEncoding() {
        #expect(throws: WAVFileError.self) {
            try WAVFile.readSamples(from: wav(samples: [0, 0], audioFormat: 3))
        }
    }

    @Test func rejectsNonRIFFBytes() {
        #expect(throws: WAVFileError.self) {
            try WAVFile.readSamples(from: Data(repeating: 0x41, count: 64))
        }
    }

    @Test func rejectsATruncatedHeader() {
        #expect(throws: WAVFileError.self) {
            try WAVFile.readSamples(from: wav(samples: [0, 0]).prefix(8))
        }
    }

    @Test func acceptsADataChunkTruncatedMidRecording() throws {
        // A crash mid-capture leaves the declared size larger than the bytes on disk.
        let full = wav(samples: [100, 200, 300, 400])
        let truncated = full.prefix(full.count - 4)

        let samples = try WAVFile.readSamples(from: Data(truncated))

        #expect(samples.count == 2)
    }

    @Test func readsFromDisk() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        try wav(samples: [0, 8192]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let samples = try WAVFile.readSamples(at: url)

        #expect(samples == [0, 0.25])
    }
}
