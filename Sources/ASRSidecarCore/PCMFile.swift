import Foundation

/// Reader for the recorder's raw `.pcm` preview tee.
///
/// Headerless 16 kHz mono s16le, written append-only while capture is live. There is no format
/// to validate and nothing to negotiate: the one producer is `MicrophoneRecorder`, and the file
/// is deleted the moment the utterance ends.
public enum PCMFile {
    /// Reads at most `limitSampleCount` samples, normalized exactly as `WAVFile` normalizes.
    ///
    /// The limit is the caller's snapshot of how many samples the writer had committed. Bytes
    /// past it may be a torn write in progress, so they are never read.
    public static func readSamples(at url: URL, limitSampleCount: Int) throws -> [Float] {
        guard limitSampleCount > 0 else { return [] }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let usable = min(limitSampleCount * 2, data.count - (data.count % 2))
        guard usable > 0 else { return [] }
        return PCMSamples.decodeInt16(data, in: data.startIndex..<(data.startIndex + usable))
    }
}

/// The one Int16 -> normalized Float conversion, shared by the WAV and PCM readers so a
/// preview decode and the final decode can never disagree about what the samples were.
enum PCMSamples {
    static func decodeInt16(_ data: Data, in range: Range<Int>) -> [Float] {
        let count = range.count / 2
        guard count > 0 else { return [] }
        let scale = Float(1.0 / 32768.0)
        return data.withUnsafeBytes { raw -> [Float] in
            [Float](unsafeUninitializedCapacity: count) { buffer, initialized in
                for index in 0..<count {
                    // Unaligned: in a WAV the data chunk starts wherever the preceding chunks
                    // leave it, and a mapped Data carries no alignment guarantee either.
                    let bits = raw.loadUnaligned(fromByteOffset: range.lowerBound + index * 2, as: UInt16.self)
                    buffer[index] = Float(Int16(bitPattern: UInt16(littleEndian: bits))) * scale
                }
                initialized = count
            }
        }
    }
}
