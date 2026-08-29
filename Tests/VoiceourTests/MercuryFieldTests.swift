import CoreGraphics
import Foundation
import Testing

@testable import VoiceCore
@testable import Voiceour

/// The invariant that keeps the clickable region and the drawn pixels from ever
/// disagreeing: they are the same scalar field.
///
/// This matters more here than on any other surface in the app. The island floats over
/// content it cannot see, and a transparent rectangle that swallows clicks the user
/// cannot see is worse than no island at all.
@MainActor
struct MercuryFieldTests {
    private static let gains = MercuryGains(drive: 1, snake: 0.011)

    private static func poses() -> [(name: String, pose: MercuryPose, samples: [Float])] {
        let speaking: [Float] = [0.08, 0.19, 0.34, 0.52, 0.71, 0.88, 0.64, 0.41, 0.27, 0.15, 0.46]
        let quiet: [Float] = [0.0, 0.02, 0.01, 0.03, 0.0, 0.04, 0.02, 0.0, 0.01, 0.05, 0.02]

        func model(_ levels: [Float], live: Bool, state: SessionState = .recording) -> RecordingOverlayModel {
            let model = RecordingOverlayModel()
            model.update(state)
            model.updateCaptureLive(live)
            for level in levels { model.record(level) }
            return model
        }

        let copied = RecordingOverlayModel()
        let copiedState = SessionState.copiedOnly(reason: "target_terminal")
        copied.update(copiedState)
        if let outcome = RecordingOverlayOutcome(state: copiedState) {
            copied.present(outcome)
        }

        let failed = RecordingOverlayModel()
        let failedState = SessionState.insertFailed(reason: "no focused element")
        failed.update(failedState)
        if let outcome = RecordingOverlayOutcome(state: failedState) {
            failed.present(outcome)
        }

        return [
            ("speaking", MercuryPose.target(for: model(speaking, live: true)), speaking),
            ("listening", MercuryPose.target(for: model(quiet, live: true)), quiet),
            ("warming", MercuryPose.target(for: model(speaking, live: false)), speaking),
            (
                "processing",
                MercuryPose.target(for: model([], live: false, state: .transcribing)),
                [Float](repeating: 0, count: 11)
            ),
            ("lurch", MercuryPose.target(for: failed), [Float](repeating: 0, count: 11)),
            ("gathered", MercuryPose.target(for: copied), [Float](repeating: 0, count: 11)),
        ]
    }

    private static func field(pose: MercuryPose, samples: [Float], seed: UInt64) -> MercuryField {
        let drive = MercurySimulation.Drive(pose: pose, samples: samples, reduceMotion: false)
        let simulation = MercurySimulation(seed: seed, gains: gains)
        simulation.reset(to: drive)
        simulation.advance(steps: 600, drive: drive)
        return MercuryField(geometry: simulation.geometry, lateralOffset: pose.lateralOffset)
    }

    /// The drawn alpha and the drag predicate answer the same question everywhere except
    /// inside the one-pixel band the coverage ramp occupies, which is the band both of
    /// them define as the boundary.
    @Test func theDrawnBodyAndTheClickableRegionAgree() {
        let environment = MercuryEnvironment(world: .roomOfTen, seed: 3)
        let response = MercuryCalibration.shared.displayResponse(
            for: environment,
            bodySeed: 3
        )
        let rasterizer = MercuryRasterizer()
        let scale = MercuryMetrics.rasterScale
        let bounds = MercuryField.islandBounds

        for seed in [UInt64(3), 29, 0x5155_4943_4B53_4C56] {
            for entry in Self.poses() where entry.pose.length > 0 {
                let field = Self.field(pose: entry.pose, samples: entry.samples, seed: seed)
                guard
                    let image = rasterizer.image(
                        field: field,
                        environment: environment,
                        response: response,
                        appearance: .standard,
                        scale: scale
                    ),
                    let alpha = Self.alphaChannel(of: image)
                else {
                    Issue.record("\(entry.name) produced no image")
                    continue
                }

                var checked = 0
                let generator = MercuryNoise(seed: seed &+ 99)
                for sample in 0..<4000 {
                    let horizontal =
                        Double(bounds.minX)
                        + generator.uniform(stream: 1, counter: UInt64(sample) &* 2) * Double(bounds.width)
                    let vertical =
                        Double(bounds.minY)
                        + generator.uniform(stream: 1, counter: UInt64(sample) &* 2 &+ 1) * Double(bounds.height)
                    let point = CGPoint(x: horizontal, y: vertical)
                    let value = Double(field.value(at: point))
                    let gradient = field.gradient(at: point)
                    let magnitude = (gradient.dx * gradient.dx + gradient.dy * gradient.dy).squareRoot()
                    // Skip the one analytic pixel of edge: inside it the two answers are
                    // allowed to differ, and outside it they may not.
                    guard magnitude > 0, abs(value) > Double(magnitude) / Double(scale) else { continue }

                    let column = Int(((horizontal - Double(bounds.minX)) * Double(scale)).rounded(.down))
                    let row = Int(((Double(bounds.maxY) - vertical) * Double(scale)).rounded(.down))
                    guard column >= 0, column < image.width, row >= 0, row < image.height else { continue }
                    let opaque = alpha[row * image.width + column] > 127
                    #expect(opaque == (value >= 0), "\(entry.name) seed \(seed) at \(point)")
                    checked += 1
                }
                #expect(checked > 500, "\(entry.name) sampled too few points to mean anything")
            }
        }
    }

    /// The 180x34 envelope is absolute. Adversarial drives included, because the meter
    /// buffer is whatever the room hands it.
    @Test func everyBodyStaysInsideTheIsland() {
        let adversarial: [[Float]] = [
            [Float](repeating: 1, count: 11),
            [1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1],
            [0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0],
        ]
        let bounds = MercuryField.islandBounds
        for seed in [UInt64(3), 29] {
            for entry in Self.poses() where entry.pose.length > 0 {
                for samples in adversarial + [entry.samples] {
                    let field = Self.field(pose: entry.pose, samples: samples, seed: seed)
                    let box = field.boundingBox
                    #expect(box.minX >= bounds.minX - 0.001)
                    #expect(box.maxX <= bounds.maxX + 0.001)
                    #expect(box.minY >= bounds.minY - 0.001)
                    #expect(box.maxY <= bounds.maxY + 0.001)
                }
            }
        }
    }

    /// A single connected component with a positive radius everywhere, so a detached
    /// speck is unrepresentable rather than merely disallowed.
    @Test func theBodyIsOneConnectedComponent() {
        for entry in Self.poses() where entry.pose.length > 0 {
            let field = Self.field(pose: entry.pose, samples: entry.samples, seed: 41)
            let half = Double(entry.pose.length) / 2
            for step in 0...200 {
                let horizontal =
                    -half
                    + 2 * half * Double(step) / 200
                    + Double(entry.pose.lateralOffset)
                let column = field.column(
                    atX: horizontal - Double(entry.pose.lateralOffset)
                )
                #expect(column.radius > 0, "\(entry.name) pinched at \(horizontal)")
                #expect(
                    field.value(
                        at: CGPoint(x: horizontal, y: column.center)
                    ) > 0
                )
            }
        }
    }

    /// AppKit points are top-down while `MercuryField` is centre-local and y-up. Hold the
    /// conversion and drag slop to the same oracle over an asymmetric speaking body.
    @Test func hitRegionConvertsPanelCoordinatesBackIntoTheField() {
        let entry = Self.poses().first { $0.name == "speaking" }!
        let field = Self.field(
            pose: entry.pose,
            samples: entry.samples,
            seed: 53
        )
        let region = MercuryHitRegion()
        region.update(field)
        let bounds = CGRect(origin: .zero, size: RecordingOverlayMetrics.windowSize)
        let island = RecordingOverlayMetrics.islandRect(in: bounds)
        let slop = MercuryMetrics.dragSlop

        for horizontal in stride(from: -88.0, through: 88.0, by: 8) {
            for vertical in stride(from: -16.0, through: 16.0, by: 4) {
                let local = CGPoint(x: horizontal, y: vertical)
                let panel = CGPoint(
                    x: island.midX + horizontal,
                    y: island.midY - vertical
                )
                #expect(
                    region.contains(panel, in: bounds, slop: slop)
                        == (field.value(at: local) >= -slop)
                )
            }
        }
    }

    private static func alphaChannel(of image: CGImage) -> [UInt8]? {
        guard let data = image.dataProvider?.data as Data? else { return nil }
        let bytesPerRow = image.bytesPerRow
        var result = [UInt8](repeating: 0, count: image.width * image.height)
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for row in 0..<image.height {
                for column in 0..<image.width {
                    result[row * image.width + column] = base[row * bytesPerRow + column * 4 + 3]
                }
            }
        }
        return result
    }
}
