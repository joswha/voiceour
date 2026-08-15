import AVFoundation
import Foundation

/// Converts microphone buffers to the app's WAV format, following the source
/// format when the hardware changes underneath.
///
/// The recorder writes the converted buffers to the one WAV the sidecar reads.
///
/// A route change is handled by the data rather than by a notification. When a
/// buffer arrives in a new format the previous converter is drained first, so its
/// resampling tail is kept instead of being dropped at the seam, and only then is
/// a replacement built. `AVCaptureSession` re-negotiates its own device, so the
/// format description on the sample buffer is the earliest and most reliable
/// notice that anything moved.
final class CaptureConverter {
    let targetFormat: AVAudioFormat

    /// True once a source format arrived that no converter could be built for.
    ///
    /// A converter that cannot follow the hardware stops contributing audio, so the
    /// recording ends short rather than wrong. The flag exists so a caller can tell
    /// a short capture from a complete one.
    private(set) var didFailToFollowFormat = false

    private var converter: AVAudioConverter?
    private let makeConverter: (AVAudioFormat, AVAudioFormat) -> AVAudioConverter?

    /// `makeConverter` exists so the unrecoverable branch is provable. Every
    /// format `AVAudioConverter` actually refuses is platform-dependent trivia, so
    /// a test that hunted for one would assert about the OS rather than about this
    /// type; injecting the refusal asserts about the behaviour that matters.
    init(
        targetFormat: AVAudioFormat,
        makeConverter: @escaping (AVAudioFormat, AVAudioFormat) -> AVAudioConverter? = {
            AVAudioConverter(from: $0, to: $1)
        }
    ) {
        self.targetFormat = targetFormat
        self.makeConverter = makeConverter
    }

    /// Converted output for one source buffer, including the previous
    /// converter's tail when the source format just changed.
    func convert(_ buffer: AVAudioPCMBuffer) -> [AVAudioPCMBuffer] {
        var out: [AVAudioPCMBuffer] = []
        if let existing = converter, existing.inputFormat != buffer.format {
            out += Self.drain(existing, to: targetFormat)
            converter = nil
        }
        if converter == nil {
            converter = makeConverter(buffer.format, targetFormat)
            if converter == nil {
                didFailToFollowFormat = true
            }
        }
        guard let converter else { return out }
        out += Self.pump(converter, input: buffer, to: targetFormat, endOfStream: false)
        return out
    }

    /// The final tail once capture has stopped. Safe to call more than once.
    func drain() -> [AVAudioPCMBuffer] {
        guard let converter else { return [] }
        self.converter = nil
        return Self.drain(converter, to: targetFormat)
    }

    private static func drain(_ converter: AVAudioConverter, to format: AVAudioFormat) -> [AVAudioPCMBuffer] {
        pump(converter, input: nil, to: format, endOfStream: true)
    }

    private static func pump(
        _ converter: AVAudioConverter,
        input: AVAudioPCMBuffer?,
        to format: AVAudioFormat,
        endOfStream: Bool
    ) -> [AVAudioPCMBuffer] {
        var pending = input
        var out: [AVAudioPCMBuffer] = []
        let sourceRate = converter.inputFormat.sampleRate
        let targetRate = format.sampleRate

        while true {
            let inputFrames = Double(pending?.frameLength ?? 0)
            let capacity = AVAudioFrameCount(
                max(256, (inputFrames * targetRate / max(sourceRate, 1)).rounded(.up) + 64))
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return out }
            var consumed = false
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, outStatus in
                if endOfStream, pending == nil {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if consumed || pending == nil {
                    outStatus.pointee = endOfStream ? .endOfStream : .noDataNow
                    return nil
                }
                consumed = true
                let next = pending
                pending = nil
                outStatus.pointee = .haveData
                return next
            }
            if output.frameLength > 0 {
                out.append(output)
            }
            switch status {
            case .haveData:
                continue
            case .inputRanDry:
                if endOfStream { continue }
                return out
            case .endOfStream, .error:
                return out
            @unknown default:
                return out
            }
        }
    }
}
