// Offscreen UI harness. Compiled only when `UI_HARNESS` is defined.
//
// Every build defines it except `scripts/bundle.sh`, whose plain
// `swift build -c release` is therefore the only build that omits the harness --
// which is the entire point: these objects used to link into the shipping binary
// even though execution was gated at runtime on `--ui-harness`.
//
// `RenderOverrides` is deliberately NOT here: many production files read it, so
// it lives in `Sources/VoiceOour/RenderOverrides.swift` and is never gated.
#if UI_HARNESS

    import AppKit
    import Foundation
    import SwiftUI
    import VoiceCore

    // Media, not goldens.
    //
    // A scene proves one state still renders; a flow proves one journey still works.
    // A reel exists for a third job neither can do: showing a moving surface to a
    // human reading the README. It renders the real SwiftUI views frame by frame
    // through the same offscreen hosting path, and `scripts/make_readme_gif.sh`
    // assembles the PNGs with ffmpeg.
    //
    // Nothing here is diffed, digested, linted, coverage-declared or gated. That is
    // deliberate: the reel's whole subject is a wall-clock-driven animation, which is
    // exactly what a reproducible golden may never contain.

    /// One frame-by-frame media reel. Not a golden: nothing here is diffed, linted or gated.
    struct UIFilmReel {
        /// Artifact directory name under `<out>/film/`, e.g. `dictation-island`.
        let id: String
        let title: String
        /// Logical points. The pixel measure is this times `--scale`.
        let size: CGSize
        let colorScheme: ColorScheme
        /// Intended playback delay per frame, carried into `reel.json` so the GIF
        /// assembler derives its frame rate from the reel rather than guessing.
        let frameMilliseconds: Int
        let stage: @MainActor () -> UIFilmStage
    }

    /// The hosted view plus the script that drives it. Built once, before hosting, so the
    /// script can retain and mutate the same observable model the view observes.
    struct UIFilmStage {
        let view: AnyView
        /// Throws rather than swallowing: a reel that silently recorded a broken frame
        /// would be spliced into the README and nothing downstream would object.
        let script: @MainActor (UIFilmRecorder) throws -> Void
    }

    /// Pumps, rasterises and numbers the frames of one reel.
    ///
    /// Deliberately dumb: no digest, no golden, no lint. The only failure mode it owns is
    /// a capture or a write that throws, and it propagates both.
    @MainActor
    final class UIFilmRecorder {
        private let view: NSView
        private let scale: Int
        private let directory: URL
        private(set) var frameCount = 0

        init(view: NSView, scale: Int, directory: URL) {
            self.view = view
            self.scale = scale
            self.directory = directory
        }

        /// Settles for a fixed pump budget, then writes `frame-NNNN.png`.
        ///
        /// The budget is a run-loop iteration count, exactly as everywhere else in the
        /// harness, never a wall-clock deadline: the reel's playback delay and its settle
        /// have to be the same number or the animation plays back at the wrong speed.
        func frame(settling milliseconds: Int) throws {
            UIHarnessRuntime.pump(iterations: UIHarnessRuntime.pumpIterations(forMilliseconds: milliseconds))
            let capture = try UIHarnessRuntime.capture(view, scale: scale)
            let name = String(format: "frame-%04d.png", frameCount)
            try capture.png.write(to: directory.appendingPathComponent(name), options: .atomic)
            frameCount += 1
        }

        func frames(_ count: Int, settling milliseconds: Int) throws {
            for _ in 0..<count {
                try frame(settling: milliseconds)
            }
        }
    }

    @MainActor
    enum UIFilmCatalog {
        static func everything() -> [UIFilmReel] {
            [dictationIsland]
        }

        /// Mirrors `UISceneCatalog.all(request:)`: the request owns the `--only`/`--except`
        /// vocabulary, so a reel cannot grow a second spelling of it. Reels carry no tags.
        static func all(request: UIHarnessRequest) -> [UIFilmReel] {
            everything().filter { request.matches(id: $0.id, tags: []) }
        }

        // MARK: - dictation-island

        /// 60 ms per frame, both as the settle budget and as the playback delay, so the
        /// recorded animation plays back at the speed it was sampled at.
        private static let frameMilliseconds = 60

        /// The island is 260x80 including its shadow bleed. 400x120 keeps an even margin of
        /// flat backdrop around it while leaving the capsule 45% of the frame width, so the
        /// pill reads as the subject rather than as something lost in a dark rectangle.
        private static let stageSize = CGSize(width: 400, height: 120)

        /// One synthetic utterance envelope, not recorded audio.
        ///
        /// A pure function of the frame index — no `Date()`, no `.random` — so the reel is
        /// the same shape on every machine even though it is not a golden. Shaped like one
        /// spoken sentence: attack, syllable dips, a breath in the middle, an emphasised
        /// run, then a decay. A sine wave reads as a test pattern rather than as speech.
        private static let speechLevels: [Float] = [
            0.06, 0.22, 0.55, 0.78, 0.81, 0.64,
            0.47, 0.29, 0.18, 0.36, 0.58, 0.72,
            0.66, 0.43, 0.24, 0.15, 0.31, 0.52,
            0.61, 0.38, 0.08, 0.05, 0.05, 0.14,
            0.42, 0.69, 0.85, 0.90, 0.88, 0.79,
            0.86, 0.72, 0.55, 0.63, 0.48, 0.34,
            0.41, 0.26, 0.19, 0.23, 0.14, 0.11,
            0.09, 0.10,
        ]

        /// The real `RecordingOverlayView` driven through the real `SessionState` sequence
        /// one dictation walks: warm-up, live speech, then the four processing states and
        /// the ready state, which is the whole point of filming it rather than snapshotting
        /// it. 5 + 44 + 7 + 12 + 7 + 14 + 10 = 99 frames, about 5.9 s of playback.
        private static var dictationIsland: UIFilmReel {
            UIFilmReel(
                id: "dictation-island",
                title: "Recording island through one dictation",
                size: stageSize,
                colorScheme: .dark,
                frameMilliseconds: frameMilliseconds
            ) {
                // Pins the comet head and the render clock before the model exists, so the
                // reel does not encode this machine's random glyph or its wall clock.
                UIFixtures.pinProcessSeams()
                let model = RecordingOverlayModel()
                return UIFilmStage(
                    view: AnyView(
                        ZStack {
                            // A FLAT opaque fill, never a gradient: a GIF holds 256 colours
                            // and a gradient bands visibly across a dark backdrop.
                            VoiceOourPalette.Ink.void
                            RecordingOverlayView(model: model, onCancel: {}, onFinish: {})
                                .frame(
                                    width: RecordingOverlayMetrics.windowSize.width,
                                    height: RecordingOverlayMetrics.windowSize.height
                                )
                        }
                    ),
                    script: { recorder in
                        // Warm-up: the pill is up and the centre reads WARMING, because
                        // no buffer carrying real audio has arrived yet.
                        model.update(.recording)
                        model.updateCaptureLive(false)
                        try recorder.frames(5, settling: frameMilliseconds)

                        // Live speech: one meter sample per frame, so the waveform scrolls
                        // at exactly the rate the frames are written.
                        model.updateCaptureLive(true)
                        for level in speechLevels {
                            model.record(level)
                            try recorder.frame(settling: frameMilliseconds)
                        }

                        // Processing. `RecordingOverlayModel.processingLabel` shortens the
                        // first of these to FINALIZING and uppercases the rest.
                        model.update(.finalizingAudio)
                        try recorder.frames(7, settling: frameMilliseconds)
                        model.update(.transcribing)
                        try recorder.frames(12, settling: frameMilliseconds)
                        model.update(.cleaning)
                        try recorder.frames(7, settling: frameMilliseconds)
                        model.update(.refining)
                        try recorder.frames(14, settling: frameMilliseconds)
                        model.update(.readyToInsert)
                        try recorder.frames(10, settling: frameMilliseconds)
                    }
                )
            }
        }
    }

#endif
